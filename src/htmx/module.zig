
const std = @import("std");

pub const config = @import("config.zig");
pub const injector = @import("injector.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const form = @import("form.zig");
pub const errors = @import("errors.zig");
pub const form_validator = @import("form_validator.zig");
pub const security = @import("security.zig");
pub const builder = @import("builder.zig");
pub const testing = @import("testing.zig");

pub const HtmxConfig = config.HtmxConfig;
pub const HtmxRequestInfo = request.HtmxRequestInfo;

pub const default_config = config.default_config;
pub const development_config = config.development_config;
pub const production_config = config.production_config;
pub const disabled_config = config.disabled_config;

pub const setConfig = injector.setConfig;
pub const getConfig = injector.getConfig;
pub const isEnabled = injector.isEnabled;
pub const injectHtmx = injector.injectHtmx;
pub const addRouteExclusion = injector.addRouteExclusion;

pub const fromRequest = request.fromRequest;
pub const isHtmxRequest = request.isHtmxRequest;
pub const isHtmxBoosted = request.isHtmxBoosted;
pub const isHtmxPartial = request.isHtmxPartial;
pub const getHtmxTarget = request.getHtmxTarget;
pub const getHtmxTrigger = request.getHtmxTrigger;
pub const getHtmxCurrentUrl = request.getHtmxCurrentUrl;
pub const getHtmxPrompt = request.getHtmxPrompt;

pub const fragment = response.fragment;
pub const fragmentWithStatus = response.fragmentWithStatus;
pub const withTrigger = response.withTrigger;
pub const withTriggerData = response.withTriggerData;
pub const withTriggerAfterSwap = response.withTriggerAfterSwap;
pub const withTriggerAfterSettle = response.withTriggerAfterSettle;
pub const htmxRedirect = response.htmxRedirect;
pub const htmxRedirectWithStatus = response.htmxRedirectWithStatus;
pub const htmxRefresh = response.htmxRefresh;
pub const withPushUrl = response.withPushUrl;
pub const withNoPushUrl = response.withNoPushUrl;
pub const withReplaceUrl = response.withReplaceUrl;
pub const withNoReplaceUrl = response.withNoReplaceUrl;
pub const withRetarget = response.withRetarget;
pub const withTarget = response.withTarget;
pub const withReswap = response.withReswap;
pub const withSwap = response.withSwap;
pub const withReselect = response.withReselect;
pub const withLocation = response.withLocation;
pub const stopPolling = response.stopPolling;
pub const replaceWith = response.replaceWith;
pub const prependTo = response.prependTo;
pub const appendTo = response.appendTo;
pub const deleteElement = response.deleteElement;
pub const withMultipleTriggers = response.withMultipleTriggers;

pub const FormParser = form.FormParser;

pub const errorFragment = errors.errorFragment;
pub const validationErrorFragment = errors.validationErrorFragment;
pub const notFoundFragment = errors.notFoundFragment;
pub const errorFragmentWithStatus = errors.errorFragmentWithStatus;
pub const fieldErrorFragment = errors.fieldErrorFragment;
pub const multipleValidationErrors = errors.multipleValidationErrors;
pub const errorWithRetry = errors.errorWithRetry;
pub const toastError = errors.toastError;
pub const inlineFieldError = errors.inlineFieldError;
pub const ValidationError = errors.ValidationError;

pub const FormValidator = form_validator.FormValidator;

pub const Security = security.Security;

pub const HtmxResponseBuilder = builder.HtmxResponseBuilder;

pub const Testing = testing.Testing;

test "module exports" {
    _ = HtmxConfig{};
    _ = default_config;
    _ = development_config;
    _ = production_config;
}

test {
    std.testing.refAllDecls(@This());
}
