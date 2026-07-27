//
//  DiscordSDKBridge.mm
//  YohakuCompanion
//
//  Objective-C++ bridge for direct Rich Presence through Discord Social SDK.
//

#import "DiscordSDKBridge.h"
#import <Foundation/Foundation.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#if __has_include("discordpp.h")
#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"
#define PR_HAS_DISCORD_SOCIAL_SDK 1
#else
#define PR_HAS_DISCORD_SOCIAL_SDK 0
#endif

static NSError *PRDiscordSDKError(NSInteger code, NSString *description) {
  return [NSError errorWithDomain:@"DiscordSocialSDKError"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : description}];
}

static std::string PRDiscordString(NSString *value) {
  const char *utf8 = value.UTF8String;
  return utf8 == nullptr ? std::string() : std::string(utf8);
}

@interface DiscordSDKBridge () {
#if PR_HAS_DISCORD_SOCIAL_SDK
  std::shared_ptr<discordpp::Client> _client;
#endif
}
@property(nonatomic) BOOL internalConnected;
@property(nonatomic) NSUInteger pendingActivityUpdateIdentifier;
@property(nonatomic) NSUInteger nextActivityUpdateIdentifier;
@property(nonatomic) NSUInteger clearAfterActivityUpdateIdentifier;
@property(nonatomic, strong) NSTimer *activityUpdateTimeoutTimer;
@property(nonatomic, strong) NSTimer *callbackPumpTimer;
@property(nonatomic) NSUInteger pendingActivityClearIdentifier;
@property(nonatomic) NSUInteger nextActivityClearIdentifier;
- (NSUInteger)beginActivityUpdate;
- (void)finishActivityUpdateWithError:(NSError *_Nullable)error
                           identifier:(NSUInteger)identifier;
- (NSUInteger)beginActivityClear;
- (void)finishActivityClearWithError:(NSError *_Nullable)error
                          identifier:(NSUInteger)identifier;
- (void)startCallbackPump;
- (void)runDiscordCallbacks:(NSTimer *)timer;
@end

@implementation DiscordSDKBridge

+ (instancetype)sharedInstance {
  static DiscordSDKBridge *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[self alloc] init];
  });
  return instance;
}

+ (BOOL)isSDKAvailable {
  return PR_HAS_DISCORD_SOCIAL_SDK;
}

- (BOOL)isConnected {
  return self.internalConnected;
}

- (NSUInteger)beginActivityUpdate {
  NSUInteger previousIdentifier = self.pendingActivityUpdateIdentifier;
  if (previousIdentifier != 0) {
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-3, @"Discord activity update was superseded")
                             identifier:previousIdentifier];
  }

  self.nextActivityUpdateIdentifier += 1;
  if (self.nextActivityUpdateIdentifier == 0) {
    self.nextActivityUpdateIdentifier = 1;
  }
  NSUInteger identifier = self.nextActivityUpdateIdentifier;
  self.pendingActivityUpdateIdentifier = identifier;
  [self.activityUpdateTimeoutTimer invalidate];
  self.activityUpdateTimeoutTimer =
      [NSTimer scheduledTimerWithTimeInterval:5.0
                                       target:self
                                     selector:@selector(activityUpdateDidTimeout:)
                                     userInfo:@(identifier)
                                      repeats:NO];
  return identifier;
}

- (void)activityUpdateDidTimeout:(NSTimer *)timer {
  NSUInteger identifier = [timer.userInfo unsignedIntegerValue];
  self.clearAfterActivityUpdateIdentifier = identifier;
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-4, @"Discord activity update timed out")
                           identifier:identifier];
}

- (void)finishActivityUpdateWithError:(NSError *)error
                           identifier:(NSUInteger)identifier {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self finishActivityUpdateWithError:error identifier:identifier];
    });
    return;
  }
  if (identifier == 0 || self.pendingActivityUpdateIdentifier != identifier) {
    return;
  }

  self.pendingActivityUpdateIdentifier = 0;
  [self.activityUpdateTimeoutTimer invalidate];
  self.activityUpdateTimeoutTimer = nil;
  [self.delegate discordSDK:self didCompleteActivityUpdateWithError:error];
}

- (NSUInteger)beginActivityClear {
  NSUInteger previousIdentifier = self.pendingActivityClearIdentifier;
  if (previousIdentifier != 0) {
    [self finishActivityClearWithError:
              PRDiscordSDKError(-11, @"Discord activity clear was superseded")
                            identifier:previousIdentifier];
  }

  self.nextActivityClearIdentifier += 1;
  if (self.nextActivityClearIdentifier == 0) {
    self.nextActivityClearIdentifier = 1;
  }
  NSUInteger identifier = self.nextActivityClearIdentifier;
  self.pendingActivityClearIdentifier = identifier;
  return identifier;
}

- (void)finishActivityClearWithError:(NSError *)error
                          identifier:(NSUInteger)identifier {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self finishActivityClearWithError:error identifier:identifier];
    });
    return;
  }
  if (identifier == 0 || self.pendingActivityClearIdentifier != identifier) {
    return;
  }

  self.pendingActivityClearIdentifier = 0;
  [self.delegate discordSDK:self didCompleteActivityClearWithError:error];
}

- (void)initializeWithApplicationId:(NSString *)applicationId {
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-5, @"Discord client was reinitialized")
                           identifier:pendingIdentifier];
  NSUInteger pendingClearIdentifier = self.pendingActivityClearIdentifier;
  [self finishActivityClearWithError:
            PRDiscordSDKError(-13, @"Discord client was reinitialized")
                          identifier:pendingClearIdentifier];
  self.clearAfterActivityUpdateIdentifier = 0;
  self.internalConnected = NO;
  [self.callbackPumpTimer invalidate];
  self.callbackPumpTimer = nil;

  long long signedApplicationIdentifier = applicationId.longLongValue;
  if (applicationId.length == 0 || signedApplicationIdentifier <= 0) {
    [self notifyDisconnected:
              PRDiscordSDKError(-1, @"Invalid Discord Application ID")];
    return;
  }

#if PR_HAS_DISCORD_SOCIAL_SDK
  _client = std::make_shared<discordpp::Client>();
  _client->SetApplicationId(
      static_cast<uint64_t>(signedApplicationIdentifier));
  [self startCallbackPump];
  self.internalConnected = YES;
  [self notifyConnected];
#else
  [self notifyDisconnected:
            PRDiscordSDKError(-2, @"Discord Social SDK is unavailable")];
#endif
}

- (void)startCallbackPump {
#if PR_HAS_DISCORD_SOCIAL_SDK
  [self.callbackPumpTimer invalidate];
  self.callbackPumpTimer =
      [NSTimer timerWithTimeInterval:0.05
                              target:self
                            selector:@selector(runDiscordCallbacks:)
                            userInfo:nil
                             repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:self.callbackPumpTimer
                            forMode:NSRunLoopCommonModes];
#endif
}

- (void)runDiscordCallbacks:(NSTimer *)timer {
#if PR_HAS_DISCORD_SOCIAL_SDK
  if (self.internalConnected && _client) {
    discordpp::RunCallbacks();
  }
#endif
}

- (void)setActivityWithDetails:(NSString *)details
                         state:(NSString *)state
                startTimestamp:(NSNumber *)startTimestamp
                  endTimestamp:(NSNumber *)endTimestamp
                 largeImageKey:(NSString *)largeImageKey
                largeImageText:(NSString *)largeImageText
                 smallImageKey:(NSString *)smallImageKey
                smallImageText:(NSString *)smallImageText {
  [self setActivityWithDetails:details
                  activityName:nil
                         state:state
                   activityType:nil
              statusDisplayType:nil
                startTimestamp:startTimestamp
                  endTimestamp:endTimestamp
                 largeImageKey:largeImageKey
                largeImageText:largeImageText
                 smallImageKey:smallImageKey
                smallImageText:smallImageText
                        buttons:nil];
}

- (void)setActivityWithDetails:(NSString *)details
                         state:(NSString *)state
                startTimestamp:(NSNumber *)startTimestamp
                  endTimestamp:(NSNumber *)endTimestamp
                 largeImageKey:(NSString *)largeImageKey
                largeImageText:(NSString *)largeImageText
                 smallImageKey:(NSString *)smallImageKey
                smallImageText:(NSString *)smallImageText
                        buttons:(NSArray<NSDictionary<NSString *, NSString *> *> *)buttons {
  [self setActivityWithDetails:details
                  activityName:nil
                         state:state
                   activityType:nil
              statusDisplayType:nil
                startTimestamp:startTimestamp
                  endTimestamp:endTimestamp
                 largeImageKey:largeImageKey
                largeImageText:largeImageText
                 smallImageKey:smallImageKey
                smallImageText:smallImageText
                        buttons:buttons];
}

- (void)setActivityWithDetails:(NSString *)details
                  activityName:(NSString *)activityName
                         state:(NSString *)state
                  activityType:(NSNumber *)activityType
             statusDisplayType:(NSNumber *)statusDisplayType
                startTimestamp:(NSNumber *)startTimestamp
                  endTimestamp:(NSNumber *)endTimestamp
                 largeImageKey:(NSString *)largeImageKey
                largeImageText:(NSString *)largeImageText
                 smallImageKey:(NSString *)smallImageKey
                smallImageText:(NSString *)smallImageText
                        buttons:(NSArray<NSDictionary<NSString *, NSString *> *> *)buttons {
  NSUInteger requestIdentifier = [self beginActivityUpdate];
  if (!self.internalConnected) {
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-6, @"Discord client is not initialized")
                             identifier:requestIdentifier];
    return;
  }

#if PR_HAS_DISCORD_SOCIAL_SDK
  if (!_client) {
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-6, @"Discord client is not initialized")
                             identifier:requestIdentifier];
    return;
  }

  discordpp::Activity activity;
  if (activityName.length > 0) {
    activity.SetName(PRDiscordString(activityName));
  }
  if (details.length > 0) {
    activity.SetDetails(PRDiscordString(details));
  }
  if (state.length > 0) {
    activity.SetState(PRDiscordString(state));
  }
  if (activityType != nil) {
    activity.SetType(static_cast<discordpp::ActivityTypes>(activityType.intValue));
  }
  if (statusDisplayType != nil) {
    activity.SetStatusDisplayType(std::optional<discordpp::StatusDisplayTypes>(
        static_cast<discordpp::StatusDisplayTypes>(statusDisplayType.intValue)));
  }

  BOOL hasStartTimestamp = startTimestamp != nil && startTimestamp.longLongValue >= 0;
  BOOL hasEndTimestamp = endTimestamp != nil && endTimestamp.longLongValue >= 0;
  if (hasStartTimestamp || hasEndTimestamp) {
    discordpp::ActivityTimestamps timestamps;
    if (hasStartTimestamp) {
      timestamps.SetStart(static_cast<uint64_t>(startTimestamp.longLongValue));
    }
    if (hasEndTimestamp) {
      timestamps.SetEnd(static_cast<uint64_t>(endTimestamp.longLongValue));
    }
    activity.SetTimestamps(timestamps);
  }

  BOOL hasAssets = largeImageKey.length > 0 || largeImageText.length > 0 ||
                   smallImageKey.length > 0 || smallImageText.length > 0;
  if (hasAssets) {
    discordpp::ActivityAssets assets;
    if (largeImageKey.length > 0) {
      assets.SetLargeImage(PRDiscordString(largeImageKey));
    }
    if (largeImageText.length > 0) {
      assets.SetLargeText(PRDiscordString(largeImageText));
    }
    if (smallImageKey.length > 0) {
      assets.SetSmallImage(PRDiscordString(smallImageKey));
    }
    if (smallImageText.length > 0) {
      assets.SetSmallText(PRDiscordString(smallImageText));
    }
    activity.SetAssets(assets);
  }

  NSUInteger buttonCount = MIN((NSUInteger)2, buttons.count);
  for (NSUInteger index = 0; index < buttonCount; index += 1) {
    NSDictionary<NSString *, NSString *> *configuration = buttons[index];
    NSString *label = configuration[@"label"];
    NSString *url = configuration[@"url"];
    if (label.length == 0 || url.length == 0) {
      continue;
    }
    discordpp::ActivityButton button;
    button.SetLabel(PRDiscordString(label));
    button.SetUrl(PRDiscordString(url));
    activity.AddButton(button);
  }

  __weak DiscordSDKBridge *weakSelf = self;
  _client->UpdateRichPresence(
      activity,
      [weakSelf, requestIdentifier](const discordpp::ClientResult &result) {
        BOOL successful = result.Successful();
        std::string resultDescription = result.ToString();
        NSString *description = @"Discord rejected the activity update";
        if (!resultDescription.empty()) {
          NSString *decodedDescription =
              [NSString stringWithUTF8String:resultDescription.c_str()];
          if (decodedDescription != nil) {
            description = decodedDescription;
          }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          DiscordSDKBridge *strongSelf = weakSelf;
          if (strongSelf == nil) {
            return;
          }
          if (strongSelf.clearAfterActivityUpdateIdentifier ==
              requestIdentifier) {
            strongSelf.clearAfterActivityUpdateIdentifier = 0;
            if (strongSelf->_client) {
              strongSelf->_client->ClearRichPresence();
            }
          }
          NSError *error = successful ? nil : PRDiscordSDKError(-7, description);
          [strongSelf finishActivityUpdateWithError:error
                                         identifier:requestIdentifier];
        });
      });
#else
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-2, @"Discord Social SDK is unavailable")
                           identifier:requestIdentifier];
#endif
}

- (void)clearActivity {
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  if (pendingIdentifier != 0) {
    self.clearAfterActivityUpdateIdentifier = pendingIdentifier;
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-8, @"Discord activity was cleared")
                             identifier:pendingIdentifier];
  }

  NSUInteger clearIdentifier = [self beginActivityClear];
#if PR_HAS_DISCORD_SOCIAL_SDK
  if (self.internalConnected && _client) {
    _client->ClearRichPresence();
  }
#endif
  [self finishActivityClearWithError:nil identifier:clearIdentifier];
}

- (void)cancelPendingActivityUpdate {
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  if (pendingIdentifier == 0) {
    return;
  }
  self.clearAfterActivityUpdateIdentifier = pendingIdentifier;
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-10, @"Discord activity update was cancelled")
                           identifier:pendingIdentifier];
}

- (void)shutdown {
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-9, @"Discord client was shut down")
                           identifier:pendingIdentifier];
  NSUInteger pendingClearIdentifier = self.pendingActivityClearIdentifier;
  [self finishActivityClearWithError:
            PRDiscordSDKError(-14, @"Discord client was shut down")
                          identifier:pendingClearIdentifier];
  self.clearAfterActivityUpdateIdentifier = 0;
  [self.activityUpdateTimeoutTimer invalidate];
  self.activityUpdateTimeoutTimer = nil;
  [self.callbackPumpTimer invalidate];
  self.callbackPumpTimer = nil;
#if PR_HAS_DISCORD_SOCIAL_SDK
  if (_client) {
    _client->ClearRichPresence();
    discordpp::RunCallbacks();
    _client.reset();
  }
#endif
  self.internalConnected = NO;
}

#pragma mark - Helpers

- (void)notifyConnected {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self notifyConnected];
    });
    return;
  }
  [self.delegate discordSDKDidConnect:self];
}

- (void)notifyDisconnected:(NSError *)error {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self notifyDisconnected:error];
    });
    return;
  }
  self.internalConnected = NO;
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  [self finishActivityUpdateWithError:error identifier:pendingIdentifier];
  NSUInteger pendingClearIdentifier = self.pendingActivityClearIdentifier;
  [self finishActivityClearWithError:error identifier:pendingClearIdentifier];
  [self.delegate discordSDKDidDisconnect:self error:error];
}

@end
