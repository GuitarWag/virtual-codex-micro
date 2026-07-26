-- Raise the iTerm2 window+tab+split whose TTY matches argv 1.
-- Returns "ok <window id> <tab index>" or "notfound".
on run argv
	set wantTTY to item 1 of argv
	tell application "System Events"
		if not (exists process "iTerm2") then return "notrunning"
	end tell
	tell application "iTerm2"
		repeat with w in windows
			set i to 0
			repeat with t in tabs of w
				set i to i + 1
				repeat with s in sessions of t
					try
						if (tty of s) is wantTTY then
							select w
							select t
							select s
							activate
							return "ok " & (id of w as text) & " " & (i as text)
						end if
					end try
				end repeat
			end repeat
		end repeat
	end tell
	return "notfound"
end run
