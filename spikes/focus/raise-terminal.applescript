-- Raise the Terminal.app window+tab whose controlling TTY matches argv 1.
-- Returns "ok <window id> <tab index>", "notfound", or "notrunning".
--
-- Note: `windows` yields POSITIONAL references (window 1, window 2, ...). Once you
-- reorder with `set index of w to 1` those references point at different windows, so
-- the window id must be captured before mutating and all further work addressed
-- through `window id <n>`. Getting this wrong silently reports the wrong window.
on run argv
	set wantTTY to item 1 of argv
	tell application "System Events"
		if not (exists process "Terminal") then return "notrunning"
	end tell
	tell application "Terminal"
		set foundID to missing value
		set foundIdx to 0
		repeat with w in windows
			set wid to id of w
			set i to 0
			repeat with t in tabs of w
				set i to i + 1
				try
					if (tty of t) is wantTTY then
						set foundID to wid
						set foundIdx to i
						exit repeat
					end if
				end try
			end repeat
			if foundID is not missing value then exit repeat
		end repeat
		if foundID is missing value then return "notfound"
		set selected of tab foundIdx of window id foundID to true
		set index of window id foundID to 1
		activate
		return "ok " & (foundID as text) & " " & (foundIdx as text)
	end tell
end run
