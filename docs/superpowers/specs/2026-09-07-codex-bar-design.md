# CodexBar Design

## Summary

CodexBar is a self-use, native macOS menu bar application that shows the current remaining Codex quota for the five-hour and weekly windows. It targets the owner's Apple M1 Pro Mac running macOS 26.5 and uses the installed `codex-cli 0.147.0` as its data source.

## Goals and Non-Goals

The menu bar SHALL continuously display `5h 80% · 周 25%`, refresh promptly, start at login when enabled, and make failures visible without replacing valid values with misleading zeros. The first version SHALL NOT store usage history, predict exhaustion, send notifications, purchase credits, self-update, or support signed distribution.

## Architecture

The app will be a SwiftUI macOS application using `MenuBarExtra`. Its components are deliberately separated:

- `CodexAppServerClient`: locates the `codex` executable, manages the `codex app-server` child process, performs the required JSON-RPC initialization, sends requests, and receives notifications.
- `RateLimitParser`: selects the general Codex limit bucket, identifies five-hour and weekly windows from their durations, and converts `usedPercent` to remaining percent.
- `UsageViewModel`: owns refresh state, last-known-good values, retry behavior, and display colors.
- `MenuBarView`: renders the menu bar label and dropdown actions.
- `LoginItemManager`: registers or removes the login item through `SMAppService`.

On launch, the app starts App Server, initializes the session, requests `account/rateLimits/read`, and subscribes to `account/rateLimits/updated`. A 60-second timer provides a fallback refresh. App Server termination triggers bounded exponential retries, capped at 60 seconds.

## Interface

The selected visual direction is “status colors.” Both windows remain visible in the menu bar. Remaining values at or above 50% are green, 20–49% are orange, and below 20% are red. Missing or stale data is gray with a warning symbol.

The dropdown contains two quota cards with reset times, connection status, “立即刷新,” a “登录时自动启动” toggle, and “退出 CodexBar.” During an error, the last successful values remain visible and the dropdown explains whether Codex CLI is missing, authentication is unavailable, App Server disconnected, or the response lacks a required window.

## Security and Persistence

CodexBar delegates authentication to Codex App Server. It does not read credential files, log or persist access tokens, or call private web endpoints directly. Only the auto-start preference and last-known-good display values may be stored in `UserDefaults`. Process arguments are constructed without shell interpolation.

## Testing

Unit tests will cover JSON-RPC framing, rate-limit bucket and window selection, remaining-percentage clamping, color thresholds, missing fields, and last-known-good fallback. Client tests will use a fake process transport to verify initialization, refresh, notifications, disconnects, and retry limits. Manual acceptance will verify menu bar rendering in light and dark modes, login startup, CLI-not-found messaging, and recovery after terminating App Server.

## Acceptance Criteria

- The menu bar shows both current remaining percentages within 60 seconds of launch.
- Usage notifications update the label without waiting for the polling interval.
- Values use the approved green, orange, red, and gray states.
- Query failures never appear as zero remaining unless the server explicitly reports 100% used.
- Login startup can be enabled and disabled from the dropdown.
- No Codex authentication secret is read or stored by the application.
