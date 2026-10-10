# Travel Agent: Workflow & Usability Review

Travel Agent is a proactive AI travel companion for iPhone. It plans the trip, then watches the day as it happens. It works from the time, your location, what you tell it, and how you answer its questions. When reality drifts from the plan, it proposes changes you apply with one tap.

This document covers:
- exactly what the agent does, when, and with which model
- every way the user and the agent talk to each other
- what state lives where
- the usability problems in the current build, and the fixes for them

> **Status:** this review was written before the fixes in section 5. Since then, F1–F4 and F6–F9 have been built: one inbox, a saved proposal with Undo, the notification policy, trip phases, the new Home layout, permissions asked in context, and daily re-arming. F5 was left out on purpose, so the live card stays on Home as a testing tool. Sections 2–4 describe the build *before* those fixes. The README has the current pipeline.

---

## 1. The brains: who does what

| Job | Model | Runs when | Output | Typical latency |
|---|---|---|---|---|
| **Plan trip** | Claude Opus 5.5 (structured JSON, one required key per day) | User taps *Plan* | N days × 5–8 time blocks (time, place, tags, cost, detail) + day title + image prompt | 20–40 s |
| **Replan day** | Claude Opus 5.5 | Check-in says `shouldReplan`, or *Running late? Ask the agent* | One decision per remaining block: keep / skip / shorten / extend / shift + message | 10–25 s |
| **Chat** | Claude Opus 5.5 (multi-turn) | User sends text or voice from Home or Chat | Reply + optional full new schedule for one day | 10–25 s |
| **Check-in** | Groq `gpt-oss-20b` | Timer, any user update, notification answer, geofence | status (on track / behind / ahead / free), headline, advice, current block, `shouldReplan` | 1–3 s |
| **Travel tips** | Groq | First time a trip is shown | 4 tips | 1–2 s |
| **Near me** | Groq | User taps *Find* in live card | 4 nearby suggestions for current place and time | 1–2 s |
| **Day images** | Pollinations (no key) | Day card appears | One cover image per day | 3–10 s |
| **Places & routes** | Apple Maps (MKLocalSearch, MKDirections) | Map opens | Pins, driving routes, drive times | 2–8 s |
| **Voice** | Apple Speech (en-IN) | Hold mic | Live transcript → sent on release | real time |

**Fallbacks:**
- With no Claude key, or with mock mode on, everything runs on a rule-based mock.
- With no Groq key, check-ins, tips and nearby suggestions use the mock.
- Every model call is logged with its tokens and cost (Settings → Debug).

---

## 2. The workflow over a trip

### 2.1 Before the trip: planning
1. **+ → Plan a trip**: destination, start date, days, budget (₹), travelers, interests.
2. Claude returns the structured plan, and the trip is saved.
3. Automation is armed straight away:
   - **Questions scheduled.** A "Done with *X*?" notification is set for the end time of every block on every day.
   - **Live Activity started.** It shows the current or next block on the Lock Screen and Dynamic Island.
   - **Geofences set.** There's a 150 m region around each of *today's* places (at most 20).
   - **Check-in timer reset.** The first check-in runs within about 20 s.

### 2.2 During the day: the loop
```
          ┌──────────── every 30 min (configurable 1–60) ─────────────┐
          │                                                          ▼
 user update / notification answer / geofence ──► CHECK-IN (Groq) ──► headline + advice
                                                       │              Live Activity updated
                                                       │              feed entry
                                                       │              notification
                                                       ▼
                                          shouldReplan? ──yes──► REPLAN (Claude)
                                                                     │
                                                                     ▼
                                                    "Should you stay? New plan ready" notification
                                                    Suggested change in agent card → Apply / Ignore
                                                                     │ Apply
                                                                     ▼
                                                    Day rewritten → questions, geofences and Live Activity re-armed
```
**What a check-in sees:**
- the time
- your GPS place name
- today's blocks, with the scheduled block marked
- everything you said in the last 4 hours
- the agent's previous advice

**Where it runs:**
- **App open:** a 20-second loop runs the check-in once the interval has passed.
- **App in background:** a BGAppRefresh task is requested for the next interval. iOS decides when (or whether) it actually runs.

### 2.3 Every way information gets in

| Input | Where | What it triggers |
|---|---|---|
| Typed or held-mic message | Home box / Chat | **Claude chat** reply (+ optional plan change); also logged as an update |
| Example chip | Home (when chat empty) | Same as above |
| "Done" / "Still here" / "Reply…" | Block-end notification | Update logged → **check-in** |
| "Done" / "Still here" | Live Activity buttons | Update logged → **check-in** |
| Arrive at / leave a planned place | Geofence | Update logged → **check-in** |
| "Hey Siri, tell Travel Agent…" | Siri / Shortcuts | Update logged → **check-in** (Siri speaks the result) |
| Widget tap | Home Screen / Lock Screen widget | Opens app with the box focused |
| *Check now* | Agent card | **Check-in** |
| *Running late? Ask the agent* | Live card | **Replan** |
| *Find* | Live card | **Near me** suggestions |

### 2.4 Everything the agent puts out

| Output | Surface |
|---|---|
| Status, headline, advice | Agent card (Home), Live Activity, notification |
| Suggested change (skip / shift / extend) | Agent card with Ignore / ✓ Apply, plus a notification |
| Chat answer + plan change | Under the Home box, and in the Chat sheet |
| "Done with X?" question | Notification at each block's end |
| Countdown "Leave in 12:00" + next stop | Live Activity |
| Feed of everything said and decided | Agent feed (Home) |
| Today's route and drive times | Mini map (Home) → full map |
| Tips | Tips card |

### 2.5 The Home screen, top to bottom
1. Trip header: destination, "Day 2 of 3"
2. Mini map: today's numbered stops, route, you
3. **Agent card**: status, headline, merged explanation, suggested change, Ignore / Apply, next check-in time
4. **One box**: *Tell or ask your agent…*, with mic and send; example chips; latest reply; *See conversation*
5. Swipeable day cards: window from 30 min ago to 3 h ahead, *Show earlier / Show later*
6. Live card: debug time picker, "I'm actually at", running late, near me, last AI call
7. Trip summary: days, travelers, spend vs budget
8. Tips
9. Agent feed
10. Other trips

---

## 3. State: what survives a relaunch

| State | Stored | Survives app kill? |
|---|---|---|
| Trips and days | SwiftData (days as JSON) | ✅ |
| Feed / user updates | SwiftData `AgentEvent` | ✅ |
| API keys | Keychain | ✅ |
| Settings, geofence names | UserDefaults | ✅ |
| Latest check-in (headline) | Memory | ❌ |
| **Pending replan** | Memory | ❌ |
| **Chat conversation and proposals** | Memory | ❌ |
| Usage / cost log | Memory | ❌ |

---

## 4. Usability problems

Ranked by how much they hurt a real traveler.

### P1: Breaks trust or the core promise
1. **Three separate places that propose plan changes.**
   - The places: the agent card's *Suggested change* (check-in → replan), the live card's *Running late* (replan), and chat proposals.
   - They don't know about each other. Applying one leaves the others stale or contradictory, and the agent card can still say "You're behind" after a chat change fixed it.
2. **The same sentence does different things depending on where you say it.**
   - "Still at the beach" typed on Home goes to Claude chat, which replies with a proposal but doesn't update the headline.
   - The same words via Siri or a notification go to a Groq check-in, which updates the headline and may replan.
   - Users can't predict the outcome.
3. **Pending plans and chat are lost when iOS kills the app.**
   - The "New plan ready" notification can open an app with no plan in it.
   - Background launches (notification answers, geofences) hit this most, and that's exactly when they matter.
4. **Notification spam and feedback loops.**
   - Every check-in posts a notification, even "On track" and even with the app open (banners are shown in the foreground).
   - Answering a question triggers a check-in, which posts another notification. A geofence enter and exit fire two.
   - After the last block it keeps saying "Day complete" every 30 minutes until midnight.
5. **Trips that haven't started (or have ended) still act as "today".**
   - Outside the trip dates the app pretends it's Day 1.
   - So a trip next month shows "Day 1 of 3", runs check-ins against it, and sends notifications.

### P2: Confusing or noisy
6. **Debug controls on the main screen.** The live card's time picker and "I'm actually at" picker are testing tools, but they sit on Home next to real features.
7. **Home is too long.** There are ten sections. The agent's reply appears between the box and the day cards, so everything jumps when it arrives.
8. **Slow answers to simple things.** Every chat message goes to Opus with thinking (10–25 s), even "I'm running late", which a 2-second check-in could handle.
9. **No undo.** Applied changes can't be reverted.
10. **Silent failures.** Errors are small grey captions, and failed background check-ins aren't visible at all.
11. **All permissions are requested on first launch** (notifications, location, then Always location) before the user has seen any value.

### P3: Edge cases that bite later
12. **Geofences only cover the day they were armed.** Day 2's places are never fenced unless the app is opened that day. Place names are geocoded, so a pin can land on the wrong spot.
13. **The Live Activity goes stale.** It only updates on in-app check-ins, and iOS ends it after about 8 hours.
14. **iOS keeps at most 64 pending notifications.** Long trips (14 days × 8 blocks) silently lose questions.
15. **Background proactivity is best-effort.** Without a push server, iOS decides when background refresh runs.

---

## 5. Proposed fixes: the target workflow

**One inbox, one pipeline, one pending proposal.**

```
 any input (box, voice, Siri, notification, Live Activity, geofence, timer)
        │
        ▼
   AGENT INBOX ──► TRIAGE (Groq, ~2 s): status + "what kind of message is this?"
        │              ├─ status update / small talk  → update headline, acknowledge
        │              ├─ question                     → answer (Groq, or Claude if it needs planning)
        │              └─ plan needs to change         → PROPOSAL (Claude)
        ▼
   ONE pending proposal (persisted) ──► agent card + chat + notification all show the same one
        │ Apply                         │ Undo (10 min)
        ▼                               ▼
   plan rewritten, everything re-armed  previous day restored
```

| # | Fix | Solves |
|---|---|---|
| F1 | Single inbox: the Home box, Siri, notifications and geofences all go through triage, which escalates to Claude only when the plan must change | P1.1, P1.2, P2.8 |
| F2 | One persisted `Proposal` (SwiftData), with replan and chat producing the same type and the agent card the single place to apply it | P1.1, P1.3 |
| F3 | Notification policy: notify only when action is needed (behind, new plan, a question), never in the foreground, never for "on track", quiet after the last block, 10-min dedupe | P1.4 |
| F4 | Trip phases: *upcoming* (countdown, no check-ins), *active*, *finished* (summary) | P1.5 |
| F5 | Move the live card to Settings → Debug; fold *Near me* into a chip ("What's near me?") | P2.6, P2.7 |
| F6 | Home order: map → agent card (with latest reply inside) → box → day cards → feed; tips and summary move to the itinerary header | P2.7 |
| F7 | Undo after Apply; visible error state on the agent card | P2.9, P2.10 |
| F8 | Ask for permissions in context: notifications after the first plan, Always location when the trip starts | P2.11 |
| F9 | Re-arm geofences, the Live Activity and questions each morning (first app open or background refresh); schedule questions only 48 h ahead | P3.12–14 |

**Where to start (highest impact for the demo):** F3 (notification policy), F1 and F2 (single inbox and persisted proposal), F4 (trip phases), then F5 (debug card out).
