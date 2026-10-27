local function w(label)
	local ok, e = pcall(function()
		local g = gethui(); local sg = Instance.new("ScreenGui"); sg.Parent = g; sg:Destroy(); return true
	end)
	print("[CAP2] "..label.." ok="..tostring(ok).." e="..tostring(e))
end
task.spawn(function()
	w("inmediato")
	task.wait(0.1)
	w("tras task.wait(0.1)")
	task.wait(2)
	w("tras task.wait(2)")
end)
