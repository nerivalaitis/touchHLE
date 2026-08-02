/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! `NSHTTPCookieStorage`.
//!
//! touchHLE has no cookie store, and no app needs one to run: the callers are
//! bundled social/analytics SDKs phoning home to servers that are long gone.
//! What matters is that they get an empty store back instead of aborting the
//! app, which is what an unimplemented class does. Sword of Fargoal's iPad
//! release reaches this through the Crystal SDK during startup.

use super::{ns_array, NSUInteger};
use crate::objc::{id, objc_classes, ClassExports, TrivialHostObject};

#[derive(Default)]
pub struct State {
    shared: Option<id>,
}

pub const CLASSES: ClassExports = objc_classes! {

(env, this, _cmd);

@implementation NSHTTPCookieStorage: NSObject

+ (id)sharedHTTPCookieStorage {
    if let Some(shared) = env.framework_state.foundation.ns_http_cookie_storage.shared {
        shared
    } else {
        let new = env.objc.alloc_static_object(
            this,
            Box::new(TrivialHostObject),
            &mut env.mem
        );
        env.framework_state.foundation.ns_http_cookie_storage.shared = Some(new);
        new
    }
}

- (id)retain { this }
- (())release {}
- (id)autorelease { this }

- (id)cookies {
    ns_array::from_vec(env, Vec::new())
}

- (id)cookiesForURL:(id)_url { // NSURL*
    ns_array::from_vec(env, Vec::new())
}

- (id)sortedCookiesUsingDescriptors:(id)_descriptors { // NSArray*
    ns_array::from_vec(env, Vec::new())
}

- (())setCookie:(id)_cookie { // NSHTTPCookie*
    // Nothing stores them, so nothing to do.
}

- (())deleteCookie:(id)_cookie { // NSHTTPCookie*
}

- (())setCookies:(id)_cookies // NSArray*
             forURL:(id)_url // NSURL*
    mainDocumentURL:(id)_main_document_url { // NSURL*
}

// NSHTTPCookieAcceptPolicyNever, which is the truth here.
- (NSUInteger)cookieAcceptPolicy {
    2
}
- (())setCookieAcceptPolicy:(NSUInteger)_policy {
}

@end

};
