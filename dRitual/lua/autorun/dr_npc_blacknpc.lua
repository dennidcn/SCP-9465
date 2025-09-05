-- testing model
list.Set("NPC", "npc_blacknpc", {
    Name = "Black NPC",
    Class = "npc_blacknpc",
    Category = "dRitual",
    Model = "models/dejtriyev/scaryblackman.mdl",
    AdminOnly = false
})

if CLIENT then
    language.Add("npc_blacknpc", "Black NPC")
end
