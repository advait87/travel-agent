# Travel Agent

**A proactive AI travel companion for iPhone that plans your trip, then looks after your day.**

Most itinerary apps hand you a static document. Travel Agent keeps watching the day as it happens: the time, where you are, what you tell it, and how you answer its questions. When the day drifts from the plan, it tells you what to change. Stayed at the beach two hours longer? It suggests skipping the fort that's least worth it, and you apply that with one tap.

> Built entirely by voice. Every prompt was dictated with [Wispr Flow](https://wisprflow.ai) into [Claude Code](https://claude.com/claude-code); no code was hand-written. Built for the Hacker House Goa Wispr Flow task.

## Features

- **Structured AI itineraries.** Claude plans every day as time blocks, each with times, a real place, tags and a cost per person. Each day gets a generated cover image.
- **Home is today:**
  - a live map of the day's stops with driving routes and your position
  - the agent's latest call
  - swipeable day cards showing the window from 30 minutes ago to 3 hours ahead, with *Show earlier / Show later*
- **One inbox for everything you say.** Type, hold the mic (speech recognition), use Siri ("Tell Travel Agent…"), answer a notification, tap a Live Activity button, or simply arrive somewhere (geofences). It all goes through the same pipeline.
- **Proactive check-ins.** Every 30 minutes the agent looks at the time, your GPS location, today's schedule and your recent updates, and works out the next best step.
- **Replans when you fall behind.** One saved suggestion lists what to skip, shift or extend, with **Ignore / Apply**, plus **Undo** for 10 minutes.
- **Chat that changes the plan.** For example: "Find me a quieter dinner spot", or "I'm tired, make this afternoon chill".
- **Nudges that respect you:**
  - a "Done with lunch?" question at the end of each block
  - a Lock Screen Live Activity with a "Leave in" countdown
  - notifications only when something needs you, never while the app is open
- **Trip phases.** Upcoming trips show a countdown, active trips are watched, and finished trips go quiet.
- **Token and cost debugger.** Every model call is logged with its tokens, cost and latency.

## How it works

```
 any input (box, voice, Siri, notification, Live Activity, geofence, 30-min timer)
        │
        ▼
   TRIAGE  (Groq · gpt-oss-20b · ~2 s)   status, headline, advice, intent: update | question | change
        │       ├─ update / question → answered right away
        │       └─ change requested or 30+ min behind
        ▼
   CLAUDE  (claude-opus-5-5, structured JSON)   rewrites the day / decides what to skip
        │
        ▼
   ONE saved PlanProposal ──► agent card + chat + notification ──► Apply / Ignore / Undo
```

| Job | Model |
|---|---|
| Plan the trip, replan, change the plan in chat | Claude Opus 5.5 (structured outputs, adaptive thinking) |
| Check-ins, triage, tips, "near me" | Groq (OpenAI-compatible; `openai/gpt-oss-20b` by default) |
| Day images | Pollinations |
| Places, routes, drive times | Apple MapKit |
| Voice | Apple Speech (hold-to-talk) |

There's a full walkthrough of the triggers, outputs, state and the usability review in [`docs/WORKFLOW.md`](docs/WORKFLOW.md).

**Tech:**
- SwiftUI and SwiftData (iOS 17+)
- WidgetKit and ActivityKit (Live Activity, with buttons that work on the Lock Screen)
- AppIntents (Siri)
- CoreLocation geofences and BGAppRefresh
- UserNotifications with reply actions
- raw HTTP calls to the Claude Messages API and Groq

## Run it

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and Xcode 16+.
2. Run `xcodegen generate` and open `TravelAgent.xcodeproj`. Set your own team in *Signing & Capabilities*.
3. Run on an iPhone or the simulator. In **Settings** (gear icon), paste a Claude API key and, optionally, a Groq key. Keys are stored in the iOS Keychain and never in the repo.
   - With no keys, or with *Use mock agent* switched on, everything runs on an offline rule-based agent.

**Useful launch arguments:**
- `-demoTrip` creates a one-day Goa trip built around the current time.
- `-resetData` wipes trips, chat, notifications, geofences and the Live Activity.

**Simulating movement on a real device** (from the Mac): `scripts/goto.sh baga-beach`. Run `scripts/goto.sh list` for all places.

## Tests

```bash
# Agent logic: time passing, arriving somewhere, running late, change requests, trip phases (13 tests, ~1 s)
xcodebuild test -project TravelAgent.xcodeproj -scheme TravelAgent \
  -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:TravelAgentTests

# UI walkthrough with a screenshot per step
TEST_RUNNER_SCREENSHOT_DIR=~/Desktop/shots xcodebuild test -project TravelAgent.xcodeproj -scheme TravelAgent \
  -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:TravelAgentUITests
```

The agent's clock, location and AI are injectable, so tests drive real-world changes deterministically. For example: at 16:30 you say "still here", so you're 2 h behind, Claude replans, Fort Aguada is skipped, and you get one notification.

## Known limits

- Background check-ins rely on iOS background refresh, so iOS decides when they actually run. True every-N-minute updates would need a push server.
- The widget is a shortcut into the app. A live widget needs App Groups, which a free developer account doesn't have.
