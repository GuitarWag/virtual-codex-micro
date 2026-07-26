-- Raise the Terminal.app window+tab whose controlling TTY matches argv 1.
-- Returns "ok <window id> <tab index>" or "notfound".
on run argv
	set wantTTY to item 1 of argv
	tell application "System Events"
		if not (exists process "Terminal") then return "notrunning"
	end tell
	tell application "Terminal"
		repeat with w in windows
			set i to 0
			repeat with t in tabs of w
				set i to i + 1
				try
					if (tty of t) is wantTTY then
						set selected of t to true
						set index of w to 1
						activate
						return "ok " & (id of w as text) & " " & (i as text)
					end if
				end try
			end repeat
		end repeat
	end tell
	return "notfound"
end run
