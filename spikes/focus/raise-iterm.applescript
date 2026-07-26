-- Raise the iTerm2 window+tab+split whose TTY matches argv 1.
-- Returns "ok <window id> <tab index> <session id>", "notfound", or "notrunning".
--
-- What does NOT work in iTerm2 3.6.11, despite the sdef advertising it:
--   set current tab of window id N to tab M      -> error -10000
--   set current session of tab M to session K    -> error -10000
--   set frontmost of window id N to true         -> error -10000
--   set index of window id N to 1                -> no error, no effect
--   select session K of tab M of window id N     -> no error, no effect (absolute
--                                                   specifiers are ignored)
-- Only `select` sent to a reference obtained by iterating the object model works,
-- and only on the innermost object: selecting the session pulls its tab and window
-- forward. Selecting the window first invalidates the positional references below
-- it, which is how you end up raising the wrong tab.
on run argv
	set wantTTY to item 1 of argv
	tell application "System Events"
		if not (exists process "iTerm2") then return "notrunning"
	end tell
	tell application "iTerm2"
		repeat with w in windows
			set wid to id of w
			set i to 0
			repeat with t in tabs of w
				set i to i + 1
				repeat with s in sessions of t
					if (tty of s) is wantTTY then
						set sid to id of s
						select s
						activate
						return "ok " & (wid as text) & " " & (i as text) & " " & sid
					end if
				end repeat
			end repeat
		end repeat
	end tell
	return "notfound"
end run
