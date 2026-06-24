 CataHaste  -  Cata-style Haste for DoTs & HoTs
 World of Warcraft 3.3.5a (WotLK)
=============================================
This is open source. Feel free to expand or change it to you likings!
Just credit me

Made in / for https://github.com/kadeshar/ASP/releases

READ END IF USED ON LIVE SERVERS!!!!
 
WHAT IT DOES
------------
Brings Cataclysm-style haste to periodic spells. Instead of only
shortening a DoT/HoT's duration, your haste adds EXTRA ticks. Yellow
floating numbers show the extra ticks above the target's nameplate.
(Nameplates MUST be on for Damage. Heals will always Show.)


REQUIREMENTS
------------
- Server: AzerothCore (or compatible core) with the Eluna engine.
- Client: World of Warcraft 3.3.5a (build 12340).


INSTALLATION
------------
The package has two parts: a server script and a client addon.

1) SERVER  (done once by the server admin)
   Copy the file
       CataHaste.lua
   into your server's Eluna script folder, e.g.
       <server>/lua_scripts/CataHaste.lua
   Then, in-game as a GM, run:
       .reload eluna
   (or restart the worldserver).

2) CLIENT  (done by every player)
   Copy the whole folder
       CataHaste
   into your WoW client's addon folder:
       World of Warcraft/Interface/AddOns/CataHaste/
   Restart the client (or type /console reloadui).

That's all - there is NOTHING to edit. It works out of the box.


HOW TO USE
----------
Click the round minimap button to open the settings window (movable across window).

  NORMAL MODE   (for players WITHOUT haste gear)
    An Off/On switch turns extra ticks on even with 0 haste. Loot,
    XP and quest credit work normally. Default is Off.

  HASTE MODE    (for players WITH haste gear, e.g. haste rings)
    Uses your real spell-haste rating.
      Loot  - extra-tick damage is capped, so kills award loot and XP.
      Power - full extra-tick damage, but NO loot. XP and kill credit
              are still granted (lootable quests will NOT complete).

Your choice is saved per character. Mode changes only take effect while
you are OUT of combat (a change made in combat applies once it ends).


FLOATING TEXT OPTIONS  (the "O" button, top-left of the settings window)
-----------------------------------------------------------------------
Opens a panel with sliders that tweak how the yellow extra-tick numbers
look and move. All values are saved per character and apply instantly
to the next tick.


OPTIONAL TUNING  (server admin, top of CataHaste.lua)
-----------------------------------------------------

This is a visual and backend simulation. Your floating combat text will show the
extra ticks, your actual target's HP will drop correctly, but your DPS Meter might
not record it. You are doing more damage than Details! thinks you are. Trust the process.

If you target 4 identical mobs with the exact same HP and cast a DoT, the Floating
numbers might do a little breakdance. This is a 3.3.5 client limitation. Enjoy the show.

NOTICE IF USED ON LIVE SERVERS!

This system communicates via hidden chat packets. If your server's Anti-Spam / Anticheat
kicks you for example during Raids while using AOE DOT (Blizzard ect) : Raise the chat
throttle limit, don't open an issue here. 

Not a problem yet since AOE does not apply extra ticks on every mob

# Author: Numi
