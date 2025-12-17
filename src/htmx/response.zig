const std = @import("std");
const Response = @import("../response.zig").Response;


pub fn fragment(html: []const u8) Response {
    return Response.html(html).withHeader("X-HTMX-Fragment", "true");
}

pub fn fragmentWithStatus(html: []const u8, status: u16) Response {
    return fragment(html).withStatus(status);
}

pub fn withTrigger(resp: Response, event_name: []const u8) Response {
    return resp.withHeader("HX-Trigger", event_name);
}

pub fn withTriggerData(resp: Response, event_json: []const u8) Response {
    return resp.withHeader("HX-Trigger", event_json);
}

pub fn withTriggerAfterSwap(resp: Response, event_name: []const u8) Response {
    return resp.withHeader("HX-Trigger-After-Swap", event_name);
}

pub fn withTriggerAfterSettle(resp: Response, event_name: []const u8) Response {
    return resp.withHeader("HX-Trigger-After-Settle", event_name);
}

pub fn htmxRedirect(url: []const u8) Response {
    return Response.noContent().withHeader("HX-Redirect", url);
}

pub fn htmxRedirectWithStatus(url: []const u8, status: u16) Response {
    return Response.noContent().withHeader("HX-Redirect", url).withStatus(status);
}

pub fn htmxRefresh() Response {
    return Response.noContent().withHeader("HX-Refresh", "true");
}

pub fn withPushUrl(resp: Response, url: []const u8) Response {
    return resp.withHeader("HX-Push-Url", url);
}

pub fn withNoPushUrl(resp: Response) Response {
    return resp.withHeader("HX-Push-Url", "false");
}

pub fn withReplaceUrl(resp: Response, url: []const u8) Response {
    return resp.withHeader("HX-Replace-Url", url);
}

pub fn withNoReplaceUrl(resp: Response) Response {
    return resp.withHeader("HX-Replace-Url", "false");
}

pub fn withRetarget(resp: Response, css_selector: []const u8) Response {
    return resp.withHeader("HX-Retarget", css_selector);
}

pub fn withTarget(resp: Response, css_selector: []const u8) Response {
    return withRetarget(resp, css_selector);
}

pub fn withReswap(resp: Response, swap_style: []const u8) Response {
    return resp.withHeader("HX-Reswap", swap_style);
}

pub fn withSwap(resp: Response, swap_style: []const u8) Response {
    return withReswap(resp, swap_style);
}

pub fn withReselect(resp: Response, css_selector: []const u8) Response {
    return resp.withHeader("HX-Reselect", css_selector);
}

pub fn withLocation(resp: Response, location_json: []const u8) Response {
    return resp.withHeader("HX-Location", location_json);
}

pub fn stopPolling() Response {
    return Response.text("").withStatus(286);
}


pub fn replaceWith(html: []const u8) Response {
    return fragment(html).withHeader("HX-Reswap", "outerHTML");
}

pub fn prependTo(html: []const u8, target: []const u8) Response {
    return fragment(html)
        .withHeader("HX-Retarget", target)
        .withHeader("HX-Reswap", "afterbegin");
}

pub fn appendTo(html: []const u8, target: []const u8) Response {
    return fragment(html)
        .withHeader("HX-Retarget", target)
        .withHeader("HX-Reswap", "beforeend");
}

pub fn deleteElement() Response {
    return fragment("").withHeader("HX-Reswap", "outerHTML");
}

pub fn withMultipleTriggers(resp: Response, events_json: []const u8) Response {
    return resp.withHeader("HX-Trigger", events_json);
}

test "fragment response" {
    const resp = fragment("<div>Hello</div>");
    try std.testing.expect(resp.getBody().len > 0);
}

test "htmxRedirect response" {
    const resp = htmxRedirect("/new-page");
    _ = resp;
}
