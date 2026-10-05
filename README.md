# LFG Filter Forever

Filters for the **Looking For Group** list in **WoW Forever**. Hide the players and groups you
are not looking for, straight from the gear button at the top right of the list.

## Features

- **Players**
  - **Level** range (minimum and maximum, either one can stay empty).
  - **Roles**: Tank, Healer, Damage. A player stays in the list if they listed at least one
    role you have ticked.
  - **Classes**: all nine, three per row.
- **Groups**
  - **Has Tank** and **Has Healer**: click to cycle between *any group*, *has one* (check mark)
    and *has none* (red cross). Looking for a group that still needs a tank? Cross *Has Tank*.
  - **Has DPS Spot**: only groups with an open damage slot.
- The list says how many players and groups your filters hide, and tells you when they hide
  everything.
- The red X on the gear (shown while any filter is on) resets everything.
- Blizzard's own *Show All Level Ranges* option is still there, at the top of the popover.
- Your own listing is never hidden. Filters are saved account-wide.
- **Localised**: English, German, Spanish (esES / esMX), French, Italian, Korean, Brazilian
  Portuguese, Russian and Chinese (zhCN / zhTW). Role and class names come from your game client.

## Notes

- The popover does not open in combat, and closes when combat starts.
- Esc closes the popover; a second Esc closes the Looking For Group window.

## Install

Download it from CurseForge or from the GitHub releases, and unzip the `LFGFilterForever` folder
into the `Interface\AddOns` folder of your WoW Forever client.

## License

MIT, see [LICENSE](LICENSE).
