# Comprehensive Percussion Instrument Mapping Table

Maps all percussion instruments to pipeline normalized lanes based on acoustic/functional characteristics.

## Mapping Logic

**kick** — Bass frequencies, foundational drum
**snare** — Sharp, articulate transients, wooden clicks, percussive attacks
**clap** — Hand percussion, natural clap sound
**hihat_closed** — Bright, tight, closed/dampened sounds, shakers, bright cymbals
**hihat_open** — Sustained, open, ringing sounds
**tom_low** — Low/deep pitched drums, low-mid hand percussion
**tom_mid** — Mid-range pitched drums, transitional percussion
**tom_high** — High-pitched drums, bright hand drums
**crash** — Explosive cymbals, large crashes
**ride** — Sustained cymbals, definition-focused cymbals
**percussion** — Unmapped/ambiguous sounds

---

## Complete Instrument Mappings

### KICK Lane
- Kick / Bass Drum
- Surdo (Brazilian bass drum)

### SNARE Lane
- Snare
- Side Stick / Rimshot
- Vibraslap (sharp percussive attack)
- Claves (wooden click, short)
- High Wood Block (wooden click, sharp)
- Castanets (wooden click, percussive)
- Short Guiro (short scrape, percussive)
- Mute Cuica (squeaky, muted, short attack)

### CLAP Lane
- Hand Clap

### HIHAT_CLOSED Lane (Bright, tight, shaker-like, closed cymbals)
- Closed Hi-Hat
- Pedal Hi-Hat
- Cowbell (high, bright, tight)
- Shaker
- Tambourine (bright, rhythmic)
- Cabasa (bright shaker)
- Maracas (bright shaker)
- Short Whistle (high, bright airy sound)
- High Agogo (bell, high, bright)
- Sleigh Bells (bright, shimmery)
- Bell Tree (bright, cascading)
- Mute Triangle (metal, muted, tight)

### HIHAT_OPEN Lane (Sustained, open, ringing)
- Open Hi-Hat
- Long Whistle (sustained, open)
- Long Guiro (sustained scrape)
- Open Triangle (metal, ringing open)

### TOM_LOW Lane (Low/deep pitched drums)
- Low Floor Tom
- Low Tom
- Low Bongo (hand drum, low pitch)
- Low Conga (hand drum, low pitch)
- Low Timbale (pitched drum, low)
- Low Wood Block (wooden click, low pitch)

### TOM_MID Lane (Mid-range pitched drums, transitional)
- Low-Mid Tom
- Hi-Mid Tom
- Low Agogo (bell, lower pitched)
- Open Cuica (squeaky, open, mid-range)

### TOM_HIGH Lane (High-pitched drums, bright hand drums)
- High Floor Tom (can be high-pitched)
- High Tom
- High Bongo (hand drum, high pitch)
- Mute High Conga (hand drum, high, muted)
- Open High Conga (hand drum, high, open)
- High Timbale (pitched drum, high)

### CRASH Lane (Explosive, collision sounds)
- Crash Cymbal 1
- Crash Cymbal 2
- Chinese Cymbal (crash-like cymbal, darker)
- Splash Cymbal (smaller crash)

### RIDE Lane (Sustained, definition-focused cymbals)
- Ride Cymbal 1
- Ride Cymbal 2
- Ride Bell

---

## Mapping Rationale by Category

### Drums (Pitched)
- **Toms, Bongos, Congas, Timbales**: Mapped by pitch (low/mid/high)
- **Floor Toms**: High floor → tom_high; Low floor → tom_low

### Cymbals (Metallic)
- **Hi-Hats**: Closed → hihat_closed; Open → hihat_open
- **Crashes**: Large explosion → crash
- **Rides**: Sustained, defined pitch → ride
- **Special**: Chinese → crash (darker character); Splash → crash (smaller)

### Hand Percussion (Shakers/Rhythm)
- **Shakers/Rhythmic**: Cowbell, Tambourine, Shaker, Cabasa, Maracas, Sleigh Bells → hihat_closed
  - *Rationale: Tight, bright, rhythmic role similar to closed hat*

### Wooden Percussion (Clicks/Articulation)
- **Sharp clicks**: Claves, Wood Blocks, Castanets → snare or (low → tom_low)
  - *Rationale: Sharp, articulate transient attack*
- **Guiro**: Short variant → snare (percussive); Long variant → hihat_open (sustained scrape)

### Whistles (Pitch + Sustain)
- **Short Whistle** → hihat_closed (high, bright, short)
- **Long Whistle** → hihat_open (sustained, open)

### Bells (Metallic Pitch)
- **Agogo, Triangle, Bell Tree**: High variants → hihat_closed; Low/open → tom_mid or hihat_open
  - *Rationale: Metallic brightness and sustain*

### World Percussion
- **Cuica** (Brazilian friction drum): Mute → snare (tight); Open → tom_mid (resonant)
- **Surdo** (Brazilian bass): → kick (foundational bass role)

---

## Test Coverage Needed

Add these to `audit-analyzer-lane-mapping.py`:

```python
WORLD_PERC = {
    "bongo", "high_bongo", "low_bongo",
    "conga", "high_conga", "low_conga", "mute_conga", "open_conga",
    "timbale", "high_timbale", "low_timbale",
    "agogo", "high_agogo", "low_agogo",
    "cuica", "mute_cuica", "open_cuica",
    "guiro", "short_guiro", "long_guiro",
    "cabasa", "maracas", "claves", "castanets",
    "woodblock", "high_woodblock", "low_woodblock",
    "whistle", "short_whistle", "long_whistle",
    "surdo", "bell_tree", "triangle",
    "vibraslap",
}
```

Map each to appropriate lane based on table above.

---

## Notes

- All instruments map to an existing lane — no wildcards needed
- Mapping prioritizes pitch and acoustic character
- Uncertain cases (e.g., Surdo) mapped to functional equivalent (kick-like bass role)
- Open vs. Mute variations split appropriately (closed → hihat_closed, open → hihat_open or tom_*)
