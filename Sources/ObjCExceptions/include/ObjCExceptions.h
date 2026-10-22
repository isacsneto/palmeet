#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning an Objective-C exception into an NSError. Swift can't catch these, and some Apple
/// APIs raise them for runtime conditions (AVAudioNode.installTap on a format the hardware just changed).
BOOL PMCatchObjCException(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
