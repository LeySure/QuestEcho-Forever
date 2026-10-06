# QuestEcho changelog

## 1.9.9
- Captions no longer print the client's raw "$" placeholders. Quest and gossip
  text is stored - and handed back by the client - with tokens still in it, so a
  line read "很高兴见到你，$c。" while the voice said 勇士. The caption now
  resolves them: `$N`/`$n`/`$C`/`$c`/`$R`/`$r` become the word the pack speaks
  for "you" (勇士 on a Chinese line, read from the line itself so a Chinese pack
  works on any client locale), `$g`/`$G`/`$T "left:right;"` take the same branch
  the pack was generated from, and `::tag::` markup is dropped.
  Known consequence: the Chinese pack was generated from the *second* branch of
  the gender token, so those lines caption (and speak) the female form - "姑娘",
  "姐妹", "女士" - for every player. Flagged, not changed: flipping it means
  regenerating those lines.

## 1.9.8
- Fixed pause (and "clear queue") no longer interrupting the line on clients that
  play through the music channel - 3.3.5a (build 12340) and TBC. Those clients
  have no `StopSound`, so once the sound-handle flag stopped being guessed from
  the interface number the stop path took the channel-blanking fallback first,
  and that fallback's CVar governs the *sound* channel: the voice simply ran to
  the end. Stopping a music-channel line is now decided before that fallback, and
  the fallback is skipped on clients that do not use the sound channel at all.
  Clients with a real sound handle (retail, Forever, classic era) and clients
  that rely on the fallback (1.12 / Turtle) are unaffected.

## 1.9.7
- The quest-log Echo button now knows which quest it is on clients where
  `GetQuestID` and `C_QuestLog.GetSelectedQuest` answer nil with the details
  panel open (this client: `GetQuestID()=nil`, and the panel title cannot be
  read either because `QuestLogDetailFrame` does not exist there). The id is
  taken from `QuestMapFrame.DetailsFrame.questID` as a fallback - the same field
  ForeverVO reads on this client - so the click finds a line instead of
  answering "no voice line for this quest", and the caption can fill in the
  title it could not read from any frame.
- `SelectQuestLogEntry` is now avoided on any client that has `C_QuestLog`, not
  only on those whose interface number calls itself modern. The Forever build
  reports 16001 while having `C_QuestLog`; it was taking the classic caption
  path, which is where the "only available to the Blizzard UI" block came from.
- `/qe diag` reports where the quest id came from (`GetQuestID` / selected /
  detailsFrame).

## 1.9.6
- Fixed the addon loading as nothing at all - no button, no minimap icon, no
  slash command and no visible error. `Core.lua` had grown to 204 top-level
  local variables; Lua allows 200 per chunk, so the file stopped parsing
  (`FrameXML.log`: "main function has more than 200 local variables") and the
  client loaded every other file with this one silently skipped. Every client
  capability flag and playback constant now lives in a single `CAP` table, which
  brings the main block back to 185 and leaves room for more detection later.

## 1.9.5
- The quest-log Echo button now sits directly to the right of the Back arrow on
  clients whose quest-map panel resolves a relative anchor against a frame other
  than the one it was given (the 1.16 build reported the button at x=1006 while
  the Back arrow it named sat at x=729 w=90). The offset is computed from the
  arrow's own rectangle instead, and is re-applied while the panel is open, so a
  panel the client rebuilds no longer strands the button at the old position.
- `/qe diag` now reports the anchor that is actually in effect (GetPoint), the
  Back frame's rectangle and the effective scales of every frame involved.
- The 1.12 compatibility layer no longer keys off the interface number. It probes
  the client for the capabilities it provides instead, and only replaces a global
  when that capability is genuinely missing. Clients whose version says "vanilla"
  but whose API is modern (Forever reports 16001) previously had `CreateFrame`,
  `GetQuestLogTitle` and `PlaySoundFile` replaced at global scope, which put
  addon code inside Blizzard's own call stack: that produced the "this function
  is only available to the Blizzard UI" block on login, discarded every sound
  handle so pause and clear never stopped a line, and handed frame scripts the
  1.12 argN globals instead of their own arguments.
- Voice lines play on the configured sound channel again on those clients, with
  a real handle that StopSound can stop, instead of falling through three
  retries. The stored channel name is case-corrected ("MASTER" to "Master")
  because the client rejects the uppercase form.

## 1.9.4
- One addon for all three clients: retail, WLK 3.3.5a and Turtle 1.12 now run the
  same code. Only the .toc file differs, because 1.12 and 3.3.5a need their own
  version-specific toc to recognise the folder.
- Fixed no sound after pausing or after clearing the queue while the status bar kept
  running: the guard that prevents overlapping playback was never cleared when a
  line was stopped, so replaying the same file was silently refused.
- Fixed the settings checkboxes showing as green blocks on retail: colouring now goes
  through SetColorTexture, restoring the gold mark.

## 1.9.3
- Retail 12.0 support: IsAddOnLoaded moved into C_AddOns, so the two remaining direct
  calls are now routed through the safe wrapper (one of them broke initialisation).
- The sound channel setting is honoured again, with a three-step fallback
  (configured channel -> Master -> single argument) so playback cannot fail silently.
- The Echo button sits next to the Back button again on modern clients.

## 1.9.2
- Runs on the 1.18 (Turtle), 3.3.5a and 2.4.3 clients from one build.
- Voice playback, pause, clear and captions work on all of them.
- The Echo button sits in the quest log, and is always available: press it to hear the
  quest on screen, or be told it has no line. It is placed beside the log's own map
  button where that exists, and beside the close button where it does not.
- The quest log's frame names differ per client, so the detail panel, the anchor and the
  quest title are each located by trying the known names and then, failing that, by
  looking through the log's own frames - the title is additionally recognised by its
  text resolving through the voice pack.
- Captions always match the voice: they come from the same pack the line is spoken
  from, so changing the interface language cannot desynchronise them.
- The status bar position is remembered between sessions.
- Fixed the minimap icon.

## 1.9.1
- Chinese and English voice packs, with captions in the language you hear.

## 1.9.0
- First release.
