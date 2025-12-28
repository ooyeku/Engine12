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
pub const oob = @import("oob.zig");
pub const components = @import("components.zig");
pub const validators = @import("validators.zig");
pub const sse = @import("sse.zig");
pub const csrf = @import("csrf.zig");

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

pub const OobSwapBuilder = oob.OobSwapBuilder;
pub const oobSwap = oob.oobSwap;
pub const oobMultiple = oob.oobMultiple;

// Component helpers
pub const ToastType = components.ToastType;
pub const ModalSize = components.ModalSize;
pub const SpinnerSize = components.SpinnerSize;
pub const AlertType = components.AlertType;
pub const toast = components.toast;
pub const toastWithDuration = components.toastWithDuration;
pub const toastDismiss = components.toastDismiss;
pub const toastResponse = components.toastResponse;
pub const modal = components.modal;
pub const modalWithOptions = components.modalWithOptions;
pub const modalWithActions = components.modalWithActions;
pub const modalClose = components.modalClose;
pub const modalResponse = components.modalResponse;
pub const confirmDialog = components.confirmDialog;
pub const confirmDialogWithLabels = components.confirmDialogWithLabels;
pub const deleteConfirm = components.deleteConfirm;
pub const loadingSpinner = components.loadingSpinner;
pub const loadingSpinnerWithSize = components.loadingSpinnerWithSize;
pub const loadingSpinnerWithText = components.loadingSpinnerWithText;
pub const skeleton = components.skeleton;
pub const emptyState = components.emptyState;
pub const emptyStateWithAction = components.emptyStateWithAction;
pub const alert = components.alert;
pub const alertWithDismiss = components.alertWithDismiss;
pub const progressBar = components.progressBar;
pub const progressBarWithLabel = components.progressBarWithLabel;
pub const pagination = components.pagination;

// SSE helpers
pub const SSEStream = sse.SSEStream;
pub const SSEEvent = sse.Event;
pub const sseEvent = sse.sseEvent;
pub const sseMessage = sse.sseMessage;
pub const sseFragment = sse.sseFragment;
pub const sseContainer = sse.sseContainer;
pub const sseSwapTarget = sse.sseSwapTarget;
pub const sseContainerWithTargets = sse.sseContainerWithTargets;

// CSRF helpers
pub const CsrfConfig = csrf.Config;
pub const CsrfTokenStore = csrf.TokenStore;
pub const csrfGenerateToken = csrf.generateToken;
pub const csrfValidateToken = csrf.validateToken;
pub const csrfHiddenInput = csrf.hiddenInput;
pub const csrfMetaTag = csrf.metaTag;
pub const csrfHxHeaders = csrf.hxHeaders;
pub const csrfHxHeadersAttribute = csrf.hxHeadersAttribute;
pub const csrfHtmxConfigScript = csrf.htmxConfigScript;
pub const csrfFormStart = csrf.formStart;
pub const csrfHtmxFormStart = csrf.htmxFormStart;
pub const csrfRequiresValidation = csrf.requiresValidation;
pub const csrfErrorResponse = csrf.errorResponse;

test "module exports" {
    _ = HtmxConfig{};
    _ = default_config;
    _ = development_config;
    _ = production_config;
}

test {
    std.testing.refAllDecls(@This());
}
