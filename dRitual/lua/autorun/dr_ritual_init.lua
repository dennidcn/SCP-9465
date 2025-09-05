-- Register the thingy
if CLIENT then
    language.Add("dr_ritual_pentagram", "Ritual Pentagram")
    
    list.Set("SpawnableEntities", "dr_ritual_pentagram", {
        PrintName = "Ritual Pentagram",
        ClassName = "dr_ritual_pentagram",
        Category = "dRitual"
    })
end

CreateConVar("dr_ritual_time", "120", FCVAR_ARCHIVE, "Time limit (seconds) to complete a ritual after channeling.")
CreateConVar("dr_ritual_channel_time", "3", FCVAR_ARCHIVE, "Channeling time (seconds) before the ritual starts.")
CreateConVar("dr_ritual_item_count", "3", FCVAR_ARCHIVE, "How many items are required for a ritual.")
CreateConVar("dr_ritual_material", "pentagram/pentagram", FCVAR_ARCHIVE, "Material path for the pentagram (e.g., pentagram/pentagram).")
CreateConVar("dr_ritual_size", "256", FCVAR_ARCHIVE, "Pentagram half-size in Hammer units (default 256, so 512x512).")
CreateConVar("dr_ritual_zoffset", "0.2", FCVAR_ARCHIVE, "Vertical offset from the surface to avoid z-fighting.")
