task.spawn(function()
	local ok, e = pcall(function()
		local g = gethui()
		local sg = Instance.new("ScreenGui")
		sg.Name = "__captest"
		sg.Parent = g
		sg:Destroy()
		return true
	end)
	print("[CAP2] task.spawn gethui-write ok=" .. tostring(ok) .. " e=" .. tostring(e))
end)
