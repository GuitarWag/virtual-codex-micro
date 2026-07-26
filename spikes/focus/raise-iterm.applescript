-- Raise the iTerm2 window+tab+split whose TTY matches argv 1.
-- Returns "ok <window id> <tab index> <session index>", "notfound", or "notrunning".
--
-- Verified against iTerm2 3.6.11. What does NOT work, despite the sdef advertising it:
--   set current tab of window id N to tab M     -> error -10000
--   set current session of tab M to session K   -> error -10000
--   set frontmost of window id N to true        -> error -10000
--   set index of window id N to 1               -> no error, no effect
--   select session K of tab M of window id N    -> no error, no effect
--                                                  (specifiers rooted at `window id`
--                                                   are silently ignored)
-- What works: `select` sent to a reference reached by iterating `windows`, applied at
-- each level from the outside in. `select <session>` alone only moves between splits
-- of the CURRENT tab; it does not switch tabs. The tab must be selected too.
on run argv
	set wantTTY to item 1 of argv
	tell application "System Events"
		if not (exists process "iTerm2") then return "notrunning"
	end tell
	tell application "iTerm2"
		-- phase 1: locate, mutating nothing (positional references die on reorder)
		set wid to missing value
		set ti to 0
		set si to 0
		repeat with w in windows
			set i to 0
			repeat with t in tabs of w
				set i to i + 1
				set j to 0
				repeat with s in sessions of t
					set j to j + 1
					if (tty of s) is wantTTY then
						set wid to id of w
						set ti to i
						set si to j
						exit repeat
					end if
				end repeat
				if wid is not missing value then exit repeat
			end repeat
			if wid is not missing value then exit repeat
		end repeat
		if wid is missing value then return "notfound"

		-- phase 2: window, then tab, then split - each addressed through a live
		-- iteration reference, re-found after every mutation
		repeat with w in windows
			if (id of w) is wid then
				select w
				exit repeat
			end if
		end repeat
		repeat with w in windows
			if (id of w) is wid then
				select tab ti of w
				exit repeat
			end if
		end repeat
		repeat with w in windows
			if (id of w) is wid then
				select session si of tab ti of w
				exit repeat
			end if
		end repeat
		activate
		return "ok " & (wid as text) & " " & (ti as text) & " " & (si as text)
	end tell
end run
