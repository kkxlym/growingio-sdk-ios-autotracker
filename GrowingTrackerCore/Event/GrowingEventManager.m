//
//  GrowingEventManager.m
//  GrowingTracker
//
//  Created by GrowingIO on 15/11/19.
//  Copyright (C) 2020 Beijing Yishu Technology Co., Ltd.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

#import "GrowingEventManager.h"

#import <UIKit/UIKit.h>

#import "GrowingBaseEvent.h"
#import "GrowingLogger.h"
#import "GrowingConfigurationManager.h"
#import "GrowingDataTraffic.h"
#import "GrowingDeviceInfo.h"
#import "GrowingDispatchManager.h"
#import "GrowingEventChannel.h"
#import "GrowingEventPersistence.h"
#import "GrowingEventRequest.h"
#import "GrowingFileStorage.h"
#import "GrowingNetworkInterfaceManager.h"
#import "GrowingPersistenceDataProvider.h"
#import "GrowingSession.h"
#import "GrowingTrackConfiguration.h"
#import "NSDictionary+GrowingHelper.h"
#import "NSString+GrowingHelper.h"
#import "GrowingEventFilter.h"
#import "GrowingAppLifecycle.h"
#import "GrowingEventNetworkService.h"
#import "GrowingServiceManager.h"

static const NSUInteger kGrowingMaxQueueSize = 10000;  // default: max event queue size there are 10000 events
static const NSUInteger kGrowingFillQueueSize = 1000;  // default: determine when event queue is filled from DB
static const NSUInteger kGrowingMaxDBCacheSize = 100;  // default: write to DB as soon as there are 300 events
static const NSUInteger kGrowingMaxBatchSize = 500;    // default: send no more than 500 events in every batch;

static const NSUInteger kGrowingUnit_MB = 1024 * 1024;

@interface GrowingEventManager () <GrowingAppLifecycleDelegate>

@property (nonatomic, strong) NSHashTable *allInterceptor;
@property (nonatomic, strong) NSLock *interceptorLock;

@property (nonatomic, strong) NSMutableArray<GrowingEventPersistence *> *eventQueue;
@property (nonatomic, strong, readonly) NSArray<GrowingEventChannel *> *allEventChannels;
@property (nonatomic, strong, readonly) NSDictionary<NSString *, GrowingEventChannel *> *eventChannelDict;
@property (nonatomic, strong, readonly) GrowingEventChannel *otherEventChannel;
@property (nonatomic, strong) dispatch_source_t reportTimer;

@property (nonatomic, strong) GrowingEventDatabase *timingEventDB;
@property (nonatomic, strong) GrowingEventDatabase *realtimeEventDB;

@property (nonatomic, assign) unsigned long long uploadEventSize;
@property (nonatomic, assign) unsigned long long uploadLimitOfCellular;
@property (nonatomic, assign) NSUInteger packageNum;

@end

@implementation GrowingEventManager

#pragma mark - Init

static GrowingEventManager *sharedInstance = nil;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        _allInterceptor = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
        _interceptorLock = [[NSLock alloc] init];
        _packageNum = kGrowingMaxBatchSize;
        // default is 10MB
        _uploadLimitOfCellular = [GrowingConfigurationManager sharedInstance].trackConfiguration.cellularDataLimit * kGrowingUnit_MB;
        [GrowingDispatchManager dispatchInGrowingThread:^{
            self->_timingEventDB = [GrowingEventDatabase databaseWithPath:[GrowingFileStorage getTimingDatabasePath]];
            self->_timingEventDB.autoFlushCount = kGrowingMaxDBCacheSize;
            
            self->_realtimeEventDB = [GrowingEventDatabase databaseWithPath:[GrowingFileStorage getRealtimeDatabasePath]];

            // clean expired event data
            [self cleanExpiredData_unsafe];
            // load eventQueue for the first time
            [self reloadFromDB_unsafe];
            
            [[GrowingAppLifecycle sharedInstance] addAppLifecycleDelegate:self];
        }];
    }
    return self;
}

#pragma mark - Configure Channels

- (void)configChannels {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSObject<GrowingEventInterceptor> *obj in self.allInterceptor) {
            if ([obj respondsToSelector:@selector(growingEventManagerChannels:)]) {
                [obj growingEventManagerChannels:[GrowingEventChannel eventChannels]];
            }
        }
        
        _allEventChannels = [GrowingEventChannel buildAllEventChannels];

        _eventChannelDict = [GrowingEventChannel eventChannelMapFromAllChannels:_allEventChannels];
        // all other events got to this category
        _otherEventChannel = [GrowingEventChannel otherEventChannelFromAllChannels:_allEventChannels];
    });
}

#pragma mark - Start Timer

- (void)startTimerSend {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL debugEnabled = GrowingConfigurationManager.sharedInstance.trackConfiguration.debugEnabled;
        if (debugEnabled) {
            // send event instantly
            return;
        }
        
        CGFloat configInterval = GrowingConfigurationManager.sharedInstance.trackConfiguration.dataUploadInterval;
        CGFloat dataUploadInterval = MAX(configInterval, 5); // at least 5 seconds
        
        dispatch_queue_t queue = dispatch_queue_create("io.growing", NULL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
        self.reportTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(self.reportTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * dataUploadInterval),  // first upload
                                  NSEC_PER_SEC * dataUploadInterval,
                                  NSEC_PER_SEC * 1);
        dispatch_source_set_event_handler(self.reportTimer, ^{
            [self sendAllChannelEvents];
        });
        dispatch_resume(_reportTimer);
    });
}

#pragma mark - Event
#pragma mark Event Send

- (void)postEventBuidler:(GrowingBaseBuilder *_Nullable)builder {
    dispatch_block_t block = ^{
        
        for (NSObject<GrowingEventInterceptor> *obj in self.allInterceptor) {
            if ([obj respondsToSelector:@selector(growingEventManagerEventTriggered:)]) {
                [obj growingEventManagerEventTriggered:builder.eventType];
            }
        }

        GrowingTrackConfiguration *trackConfiguration = GrowingConfigurationManager.sharedInstance.trackConfiguration;
        if (!trackConfiguration.dataCollectionEnabled) {
            GIOLogDebug(@"Data collection is disabled, event can not build");
            return;
        }
        
        // 判断当前事件是否被过滤，否则不发送
        if([GrowingEventFilter isFilterEvent:builder.eventType]){
            return;
        }

        if (![GrowingSession currentSession].createdSession) {
            [[GrowingSession currentSession] forceReissueVisit];
        }

        [builder readPropertyInMainThread];

        for (NSObject<GrowingEventInterceptor> *obj in self.allInterceptor) {
            if ([obj respondsToSelector:@selector(growingEventManagerEventWillBuild:)]) {
                [obj growingEventManagerEventWillBuild:builder];
            }
        }
        // TODO: active在page事件之后的情况处理,添加一个interceptor
        GrowingBaseEvent *event = builder.build;

        for (NSObject<GrowingEventInterceptor> *obj in self.allInterceptor) {
            if ([obj respondsToSelector:@selector(growingEventManagerEventDidBuild:)]) {
                [obj growingEventManagerEventDidBuild:event];
            }
        }
        [self writeToDatabaseWithEvent:event];
    };
    [GrowingDispatchManager dispatchInGrowingThread:block];
}

- (void)sendAllChannelEvents {
    [GrowingDispatchManager dispatchInGrowingThread:^{
        [self flushDB];
        if (!self.allEventChannels) {
            return;
        }
        for (GrowingEventChannel *channel in self.allEventChannels) {
            [self sendEventsOfChannel_unsafe:channel];
        }
    }];
}

- (void)sendEventsInstantWithChannel:(GrowingEventChannel *)channel {
    [GrowingDispatchManager dispatchInGrowingThread:^{
        [self flushDB];
        [self sendEventsOfChannel_unsafe:channel];
    }];
}

// 非安全 发送日志
- (void)sendEventsOfChannel_unsafe:(GrowingEventChannel *)channel {
    NSString *projectId = GrowingConfigurationManager.sharedInstance.trackConfiguration.projectId;
    if (projectId.length == 0) {
        GIOLogError(@"No valid ProjectId (channel = %zd).", [self.allEventChannels indexOfObject:channel]);
        return;
    }

    if (!channel.isCustomEvent && self.eventQueue.count == 0) {
        return;
    }

    if (channel.isUploading) {
        return;
    }

    [[GrowingNetworkInterfaceManager sharedInstance] updateInterfaceInfo];
    BOOL isViaCellular = NO;
    // 没网络 直接返回
    if (![GrowingNetworkInterfaceManager sharedInstance].isReachable) {
        // 没网络 直接返回
        GIOLogDebug(@"No availabel Internet connection, delay upload (channel = %zd).",
                    [self.allEventChannels indexOfObject:channel]);
        return;
    }
    NSUInteger policyMask = GrowingEventSendPolicyInstant;
    if ([GrowingNetworkInterfaceManager sharedInstance].WiFiValid) {
        policyMask = GrowingEventSendPolicyInstant | GrowingEventSendPolicyMobileData | GrowingEventSendPolicyWiFi;
        
    } else if ([GrowingNetworkInterfaceManager sharedInstance].WWANValid) {
        if (self.uploadEventSize < self.uploadLimitOfCellular) {
            GIOLogDebug(@"Upload key data with mobile network (channel = %zd).",
                        [self.allEventChannels indexOfObject:channel]);
            policyMask = GrowingEventSendPolicyInstant | GrowingEventSendPolicyMobileData;
            isViaCellular = YES;
        } else {
            GIOLogDebug(@"Mobile network is forbidden. upload later (channel = %zd).",
                        [self.allEventChannels indexOfObject:channel]);
            //实时发送策略无视流量限制
            policyMask = GrowingEventSendPolicyInstant;
        }
    }

    NSArray<GrowingEventPersistence *> *events = [self getEventsToBeUploadUnsafe:channel policy:policyMask];
    if (events.count == 0) {
        return;
    }

    channel.isUploading = YES;

    NSArray<NSString *> *rawEvents = [GrowingEventPersistence buildRawEventsFromEvents:events];

#ifdef DEBUG
    [self prettyLogForEvents:rawEvents withChannel:channel];
#endif
    /// 如果需要改变发送地址以及请求参数
    NSObject<GrowingRequestProtocol> *eventRequest = nil;
    for (NSObject<GrowingEventInterceptor> *obj in self.allInterceptor) {
        if ([obj respondsToSelector:@selector(growingEventManagerRequestWithChannel:)]) {
            eventRequest = [obj growingEventManagerRequestWithChannel:channel];
            if (eventRequest) {
                break;
            }
        }
    }
    if (!eventRequest) {
        eventRequest = [[GrowingEventRequest alloc] initWithEvents:rawEvents];
    } else {
        eventRequest.events = rawEvents;
    }

    id <GrowingEventNetworkService> service = [[GrowingServiceManager sharedInstance] createService:@protocol(GrowingEventNetworkService)];
    if (!service) {
        GIOLogError(@"-sendEventsOfChannel_unsafe: error : no network service support");
        return;
    }
    [service sendRequest:eventRequest completion:^(NSHTTPURLResponse * _Nonnull httpResponse, NSData * _Nonnull data, NSError * _Nonnull error) {
        if (error) {
            [GrowingDispatchManager dispatchInGrowingThread:^{
                channel.isUploading = NO;
            }];
        }
        if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
            [GrowingDispatchManager dispatchInGrowingThread:^{
                if (isViaCellular) {
                    self.uploadEventSize += eventRequest.outsize;
                }
                [self removeEvents_unsafe:events forChannel:channel];
                channel.isUploading = NO;

                // 如果剩余数量 大于单包数量  则直接发送
                if (channel.isCustomEvent && self.realtimeEventDB.countOfEvents >= self.packageNum) {
                    [self sendAllChannelEvents];
                }

                if (!channel.isCustomEvent && self.eventQueue.count >= self.packageNum) {
                    [self sendAllChannelEvents];
                }
            }];
        } else {
            [GrowingDispatchManager dispatchInGrowingThread:^{
                channel.isUploading = NO;
            }];
        }
    }];
}

#pragma mark Event Persist

- (void)loadFromDB_unsafe {
    NSInteger keyCount = self.timingEventDB.countOfEvents;
    NSInteger qCount = self.eventQueue.count;

    if (self.eventQueue && qCount == keyCount) {
        return;
    }

    self.eventQueue = [[NSMutableArray alloc] init];
    NSArray *array = [self.timingEventDB getEventsWithPackageNum:kGrowingMaxQueueSize];
    [self.eventQueue addObjectsFromArray:array];
}

- (void)writeToDatabaseWithEvent:(GrowingBaseEvent *)event {
    GIOLogDebug(@"save: event, type is %@\n%@", event.eventType,
                [event.toDictionary growingHelper_beautifulJsonString]);
    NSString *eventType = event.eventType;

    if (!event) {
        return;
    }

    GrowingEventChannel *eventChannel = self.eventChannelDict[eventType] ?: self.otherEventChannel;
    BOOL isCustomEvent = eventChannel.isCustomEvent;
    NSString *uuidString = [NSUUID UUID].UUIDString;
    GrowingEventPersistence *waitForPersist = [GrowingEventPersistence persistenceEventWithEvent:event uuid:uuidString];

    if (!isCustomEvent)  // custom event never goes into self.eventQueue, event can not be nil
    {
        [self.eventQueue addObject:waitForPersist];
    }

    GrowingEventDatabase *db = (isCustomEvent ? self.realtimeEventDB : self.timingEventDB);

    [db setEvent:waitForPersist forKey:uuidString];

    BOOL debugEnabled = GrowingConfigurationManager.sharedInstance.trackConfiguration.debugEnabled;
    if (GrowingEventSendPolicyInstant & event.sendPolicy || debugEnabled) {  // send event instantly
        [self sendEventsInstantWithChannel:eventChannel];
    }
}

- (void)flushDB {
    [self.timingEventDB flush];
}

- (void)removeEvents_unsafe:(NSArray<__kindof GrowingEventPersistence *> *)events
                 forChannel:(GrowingEventChannel *)channel {
    if (channel.isCustomEvent) {
        for (NSInteger i = 0; i < events.count; i++) {
            [self.realtimeEventDB setEvent:nil forKey:events[i].eventUUID];
        }

    } else {
        [self.eventQueue removeObjectsInArray:events];

        for (NSInteger i = 0; i < events.count; i++) {
            [self.timingEventDB setEvent:nil forKey:events[i].eventUUID];
        }

        if (self.eventQueue.count <= kGrowingFillQueueSize) {
            [self loadFromDB_unsafe];
        }
    }
}

- (NSArray<GrowingEventPersistence *> *)getEventsToBeUploadUnsafe:(GrowingEventChannel *)channel policy:(NSUInteger)mask {
    if (channel.isCustomEvent) {
        return [self.realtimeEventDB getEventsWithPackageNum:self.packageNum policy:mask];
    } else {
        NSMutableArray<GrowingEventPersistence *> *events =
            [[NSMutableArray alloc] initWithCapacity:self.eventQueue.count];
        NSArray<NSString *> *eventTypes = channel.eventTypes;
        const NSUInteger eventTypesCount = eventTypes.count;
        NSUInteger count = 0;
        for (GrowingEventPersistence *e in self.eventQueue) {
            if (e.policy & mask) {
                NSString *type = e.eventType;
                // 反向匹配（排除法）event of other type not match eventChannelDict`s all t
                if ((eventTypesCount == 0 && self.eventChannelDict[type] == nil) ||
                    (eventTypesCount > 0 && [eventTypes indexOfObject:type] != NSNotFound))  // 正向匹配
                {
                    [events addObject:e];
                    count++;
                    if (count >= self.packageNum) {
                        break;
                    }
                }
            }
        }
        return events;
    }
}

- (void)cleanExpiredData_unsafe {
    [self.timingEventDB cleanExpiredDataIfNeeded];
    [self.realtimeEventDB cleanExpiredDataIfNeeded];
}

- (void)reloadFromDB_unsafe {
    self.eventQueue = nil;
    [self loadFromDB_unsafe];
}

- (void)clearAllEvents {
    self.eventQueue = [[NSMutableArray alloc] init];
    [GrowingDispatchManager dispatchInGrowingThread:^() {
        [self.timingEventDB clearAllItems];
        [self.realtimeEventDB clearAllItems];
    }];
}

#pragma mark Event Log

- (void)prettyLogForEvents:(NSArray<NSString *> *)events withChannel:(GrowingEventChannel *)channel {
    NSMutableArray *arrayM = [NSMutableArray array];
    for (NSString *rawEvent in events) {
        [arrayM addObject:[rawEvent growingHelper_jsonObject]];
    }
    GIOLogDebug(@"(channel = %@, events = %@)\n", channel.urlTemplate, arrayM);
}

#pragma mark - Interceptor

- (void)addInterceptor:(NSObject<GrowingEventInterceptor> *_Nonnull)interceptor {
    if (!interceptor) {
        return;
    }
    [self.interceptorLock lock];
    [self.allInterceptor addObject:interceptor];
    [self.interceptorLock unlock];
}

- (void)removeInterceptor:(NSObject<GrowingEventInterceptor> *_Nonnull)interceptor {
    if (!interceptor) {
        return;
    }
    [self.interceptorLock lock];
    [self.allInterceptor removeObject:interceptor];
    [self.interceptorLock unlock];
}

#pragma mark - GrowingAppLifecycleDelegate

- (void)applicationDidEnterBackground {
    [self flushDB];
}

#pragma mark - Setter & Getter

- (unsigned long long)uploadEventSize {
    return [GrowingDataTraffic cellularNetworkUploadEventSize];
}

- (void)setUploadEventSize:(unsigned long long)uploadEventSize {
    [GrowingDataTraffic cellularNetworkStorgeEventSize:uploadEventSize];
}

@end
