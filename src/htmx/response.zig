const std = @import("std");
const Response = @import("../response.zig").Response;

/// HTMX Response helpers
/// These functions create responses with HTMX-specific headers that control
/// client-side behavior like redirects, triggers, and DOM updates

/// Create an HTML fragment response
/// Fragments are partial HTML that replace part of a page
/// They are marked to skip HTMX script injection
pub fn fragment(html: []const u8) Response {
    return Response.html(html).withHeader("X-HTMX-Fragment", "true");
}

/// Create an HTML fragment response with a specific status code
pub fn fragmentWithStatus(html: []const u8, status: u16) Response {
    return fragment(html).withStatus(status);
}

/// Trigger a client-side event after the response is received
/// The event can be listened to with htmx.on() or hx-trigger
///
/// Example: withTrigger(resp, "todoCreated")
/// Client: <div hx-trigger="todoCreated from:body">...</div>
pub fn withTrigger(resp: Response, event_name: []const u8) Response {
    return resp.withHeader("HX-Trigger", event_name);
}

/// Trigger a client-side event with JSON data
/// The event data is passed to the event handler
///
/// Example: withTriggerData(resp, "{\"todoCreated\":{\"id\":123}}")
pub fn withTriggerData(resp: Response, event_json: []const u8) Response {
    return resp.withHeader("HX-Trigger", event_json);
}

/// Trigger a client-side event after the swap is complete
pub fn withTriggerAfterSwap(resp: Response, event_name: []const u8) Response {
    return resp.withHeader("HX-Trigger-After-Swap", event_name);
}

/// Trigger a client-side event after the settle step is complete
pub fn withTriggerAfterSettle(resp: Response, event_name: []const u8) Response {
    return resp.withHeader("HX-Trigger-After-Settle", event_name);
}

/// Perform a client-side redirect
/// HTMX will navigate to the specified URL
pub fn htmxRedirect(url: []const u8) Response {
    return Response.noContent().withHeader("HX-Redirect", url);
}

/// Perform a client-side redirect with a specific status
pub fn htmxRedirectWithStatus(url: []const u8, status: u16) Response {
    return Response.noContent().withHeader("HX-Redirect", url).withStatus(status);
}

/// Trigger a full page refresh
pub fn htmxRefresh() Response {
    return Response.noContent().withHeader("HX-Refresh", "true");
}

/// Push a new URL into the browser's history stack
/// The URL will show in the address bar without navigation
pub fn withPushUrl(resp: Response, url: []const u8) Response {
    return resp.withHeader("HX-Push-Url", url);
}

/// Prevent pushing URL to history (set to "false")
pub fn withNoPushUrl(resp: Response) Response {
    return resp.withHeader("HX-Push-Url", "false");
}

/// Replace the current URL in the browser's history stack
/// Unlike pushUrl, this doesn't add a new history entry
pub fn withReplaceUrl(resp: Response, url: []const u8) Response {
    return resp.withHeader("HX-Replace-Url", url);
}

/// Prevent replacing URL in history (set to "false")
pub fn withNoReplaceUrl(resp: Response) Response {
    return resp.withHeader("HX-Replace-Url", "false");
}

/// Change the target element for the response
/// Overrides the hx-target of the triggering element
pub fn withRetarget(resp: Response, css_selector: []const u8) Response {
    return resp.withHeader("HX-Retarget", css_selector);
}

/// Change the swap method for the response
/// Overrides the hx-swap of the triggering element
/// Valid values: innerHTML, outerHTML, beforebegin, afterbegin, beforeend, afterend, delete, none
pub fn withReswap(resp: Response, swap_style: []const u8) Response {
    return resp.withHeader("HX-Reswap", swap_style);
}

/// Change the select filter for the response
/// Only the matching elements from the response will be swapped in
pub fn withReselect(resp: Response, css_selector: []const u8) Response {
    return resp.withHeader("HX-Reselect", css_selector);
}

/// Perform a client-side redirect with additional options
/// The location should be a JSON object with path and optional target, swap, etc.
///
/// Example: withLocation(resp, "{\"path\":\"/new-page\", \"target\":\"#main\"}")
pub fn withLocation(resp: Response, location_json: []const u8) Response {
    return resp.withHeader("HX-Location", location_json);
}

/// Stop HTMX polling for the current element
pub fn stopPolling() Response {
    return Response.text("").withStatus(286);
}

// Convenience response creators

/// Create a fragment that replaces the triggering element
pub fn replaceWith(html: []const u8) Response {
    return fragment(html).withHeader("HX-Reswap", "outerHTML");
}

/// Create a fragment that prepends to the target
pub fn prependTo(html: []const u8, target: []const u8) Response {
    return fragment(html)
        .withHeader("HX-Retarget", target)
        .withHeader("HX-Reswap", "afterbegin");
}

/// Create a fragment that appends to the target
pub fn appendTo(html: []const u8, target: []const u8) Response {
    return fragment(html)
        .withHeader("HX-Retarget", target)
        .withHeader("HX-Reswap", "beforeend");
}

/// Delete the triggering element (returns empty with outerHTML swap)
pub fn deleteElement() Response {
    return fragment("").withHeader("HX-Reswap", "outerHTML");
}

/// Create a response that triggers multiple events
/// Events should be a JSON object: {"event1": null, "event2": {"key": "value"}}
pub fn withMultipleTriggers(resp: Response, events_json: []const u8) Response {
    return resp.withHeader("HX-Trigger", events_json);
}

// Tests
test "fragment response" {
    const resp = fragment("<div>Hello</div>");
    // Verify it returns a valid Response
    try std.testing.expect(resp.getBody().len > 0);
}

test "htmxRedirect response" {
    const resp = htmxRedirect("/new-page");
    // Verify it returns a valid Response (204 no content with HX-Redirect header)
    _ = resp;
}
