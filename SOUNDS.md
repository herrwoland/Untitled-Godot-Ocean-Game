# Sound effects to add

Every node below already exists and is wired up in code. It stays silent until it
has a sound, so nothing breaks while one is missing. To add a sound, select the node
and drag the file into its **Stream**.

- **Loop** means the sound must repeat seamlessly. After dragging the file in, select
  it in the FileSystem dock, open the **Import** tab, set **Loop** on (WAV: Loop Mode
  → Forward) and press **Reimport**.
- **3D** sounds come from a place in the world, so **mono** files work best. The game
  pans and fades them by itself.

## The boat (`assets/models/ship/boat.tscn`)

- [ ] **EngineLoop**: engine running. *Loop, 3D.* It only plays while you're at the
  helm with the throttle open, and gets louder and higher-pitched with throttle.
  Record one steady middle speed.
- [ ] **CoughSound**: the engine misfiring when the furnace is low on fuel: a choke, a
  bang in the exhaust. *One-shot, 3D.* Plays on each cough, more often as the fuel runs out
  (the engine loop dips at the same moment).
- [ ] **HullWaterLoop**: water slapping and sloshing against the hull. *Loop, 3D.*
  Plays all the time.
- [ ] **CreakLoop**: the wooden boat creaking as it rolls. *Loop, 3D.* Plays all the
  time, so keep it sparse: a creak every few seconds with quiet in between.
- [ ] **front_light_hinge/SwitchOnSound**: heavy switch, lamp coming on (a clunk,
  maybe a buzz as it warms up). *One-shot, 3D.*
- [ ] **front_light_hinge/SwitchOffSound**: the same switch going off. *One-shot, 3D.*
- [ ] **front_light_hinge/TurnSound**: the searchlight mount grinding as it swings.
  *Loop, 3D.* It fades in while the light moves, gets louder and a little higher the
  faster you turn, and fades out when you stop or hit a limit. A dry metal bearing
  grind works well.

## Fuel dispenser (`scenes/boat/dispenser.tscn`)

- [ ] **OpenSound**: handle pulled, shutters rolling open, the platform rising with a
  fuel cell. *One-shot, 3D.* Plays at the start of "open" (1.2 s).
- [ ] **CloseSound**: handle pulled back, shutters closing. *One-shot, 3D.* Plays at the
  start of "close" (0.5 s).

## The player (`assets/player/player.tscn`)

- [ ] **SplashPlayer**: body hitting the water (jumping or falling in). *One-shot.*
- [ ] **GaspPlayer**: sharp breath on surfacing after a long dive (over 4 s under).
  *One-shot.*
- [ ] **HeartbeatPlayer**: *optional.* A heartbeat is already generated in code
  while you run out of air. A real recording would replace it; tell me and I'll
  switch it over.

## Creatures

- [ ] **hunter_fish.tscn → PresenceLoop**: low throb of something below you, for as
  long as it hunts. *Loop, 3D.* Should be felt more than heard. Optional —
  leave empty if SneakLoop covers it.
- [ ] **hunter_fish.tscn → SneakLoop**: the subtle sound of it stalking you, only
  while it sneaks; stops the moment it is seen. *Loop, 3D, heard within 80 m.*
- [ ] **hunter_fish.tscn → DetectSound**: the instant it knows you've seen it.
  *One-shot, 3D.*
- [ ] **hunter_fish.tscn → ChargeSound**: the rush, at the start of each charge
  (plays again on every pass). Cut off by the bite. *One-shot, 3D.*
- [ ] **hunter_fish.tscn → BiteSound**: the jaws closing on you. *One-shot, 3D.*
- [ ] **eel.tscn → EelLoop**: the eel's presence (slithering, a wet hum). *Loop, 3D.*

## World (`main.tscn`)

- [ ] **MusicPlayer**: music. Plays from the start at −8 dB. Loop it if it's a bed
  of sound, leave it one-shot if it's a piece.
- [ ] **StonyBeach/…/Light_House_light_0_1/FoghornPlayer**: the lighthouse foghorn.
  *3D, heard up to 1.5 km away.* Loop a single long blast with a lot of silence
  after it, so it sounds every half minute or so.

## UI (`assets/ui/note_view.tscn`)

- [ ] **PaperPlayer**: paper rustle when a letter or note opens or turns. *One-shot.*

## Optional: sounds currently made in code

These already play a stand-in generated in code. A real recording would likely be
better. Tell me when you have one and I'll switch it over (it needs a small code
change).

- [ ] Heartbeat while out of air (`oxygen_controller.gd`)
- [ ] Deep rumble when something huge passes below (`deep_passing.gd`)
- [ ] Rain hiss (`rain.gd`)
- [ ] The "strangeness" sting (`strangeness_sting.gd`)

## Ideas: no node yet

Worth adding for the feel of the game. Tell me which ones you want and I'll wire
them up, then they join the list above.

- Footsteps on the wooden deck, on stone, and wading in shallows
- Hands on the ladder while climbing aboard
- Taking and letting go of the helm and the searchlight (a hand on metal or wood)
- Picking up and putting down the package
- Muffled underwater drone, the pressure of being under
- The bed and falling asleep, the start of a new day
- Menu button clicks and hover
