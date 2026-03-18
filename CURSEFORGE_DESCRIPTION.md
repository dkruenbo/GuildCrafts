# GuildCrafts

**Find guild crafters instantly.**

Stop asking in guild chat *“Can anyone craft this?”* and waiting for replies.

GuildCrafts automatically builds a **shared crafting database for your guild**.  
Search any item and instantly see **who can craft it**.

You can even search directly from guild chat.

`!gc shadowcloth`  
`!gc spellstrike hood`  
`!gc flask`

GuildCrafts automatically replies with matching crafters — **no addon required for the person asking**.

---

# Core Features

### Guild Chat Craft Lookup

Perfect for quickly finding crafters during raids, farming sessions, or when browsing the auction house.

Just type:

`!gc <item name>`

GuildCrafts will reply with **guild members who can craft it**.

Players asking the question **do not need the addon installed**.

### Shared Guild Recipe Database

GuildCrafts combines the recipes of all addon users into a **single guild recipe book**.

Search by:

* recipe name  
* crafted item  
* profession  

Instantly see **which guild members can craft what**.

The more guild members who install the addon, the more complete the database becomes.

### Item Tooltip Integration

GuildCrafts injects crafter info directly into native item tooltips.

Hover any item anywhere in the game:

* bags  
* auction house  
* trade chat  
* mail  
* tooltips  

GuildCrafts shows **which guild members can craft that item** — no asking in chat or checking external websites.

---

# Recipe Browser

GuildCrafts includes a full crafting browser for your guild.

Browse professions and recipes in two ways:

### Members View

See **every recipe known by a specific guild member**.

Useful when you already know who might craft something.

### Recipes View

See **every guild member who can craft a recipe**.

* Hover recipes to inspect the crafted item or spell
* Expand recipes to view reagent materials
* Hover reagents to inspect them
* Hover the crafter preview to see the full crafter list
* Click `[W]` to whisper a crafter directly — chat opens pre-filled, you review before sending
* Click `[>]` to post crafters directly to guild chat

This makes it easy to see **who can craft something and what it costs** at a glance.

### Online Filter & Tooltip Toggle

Two toggle buttons sit in the **bottom bar** of the GuildCrafts window.

**[Online]** hides offline members across the member list, crafter lists, and profession counts. The button glows gold when the filter is active.

**[Tooltip]** controls whether GuildCrafts injects crafter info into item tooltips. Disable it when popular items (flasks, enchants) generate tooltips that are too long in large guilds. The setting persists across sessions.

**[Minimap]** shows or hides the minimap icon without needing a slash command. Glows gold when the minimap button is visible.

### Online Status Indicator

Every member row shows a small coloured `O` dot:

* **Green** — online and GuildCrafts is active this session
* **Yellow** — online, but GuildCrafts not detected (may have uninstalled)
* **Grey** — offline

Hover the dot to see a tooltip explaining the status.

---

# Quality of Life

### Favorites

Star recipes or crafters you use often and access them instantly from the Favorites tab.

Perfect for things like:

* regular raid consumables  
* enchant contacts  
* crafting partners

### Cooldown Tracking

GuildCrafts tracks profession cooldowns across your guild.

Examples include:

* Mooncloth  
* Shadowcloth  
* Spellcloth  
* Transmutes  

Quickly see **which cooldowns are available**.

### Specializations

GuildCrafts tracks profession specializations such as:

* Transmutation Master  
* Mooncloth Tailoring  
* Spellfire Tailoring  
* Goblin / Gnomish Engineering  

So you always know **who can craft which variant**.

Hover the specialization label in a member's detail panel to see a plain-English description of what it unlocks.
* collapsible reagent lists  
* profession icons  
* favorites system  
* crafter preview on recipe rows  
* minimap button  

Everything is built to stay **fast and easy to scan**.

---

# Setup

Getting started takes less than a minute.

1. Install the addon  
2. Open each of your profession windows once  
3. Done

Your recipes will now automatically sync with other guild members who use the addon.

---

# Supported Version

Built for **WoW TBC Anniversary Edition**  
Interface version **20505**

Supports all crafting and gathering professions:

**Crafting:** Alchemy · Blacksmithing · Enchanting · Engineering · Jewelcrafting · Leatherworking · Tailoring

**Secondary:** Mining (incl. Smelting) · Herbalism · Skinning · Cooking

Gathering professions track skill levels and member counts. Mining additionally tracks Smelting recipes.

---

# Commands

`/gc`  
Open the GuildCrafts window.

`/gc minimap`  
Toggle the minimap button.

`/gc reset`  
Clear your local database and re-scan recipes.

`!gc <query>`  
Search for crafters directly from **guild chat**.

Example:

`!gc shadowcloth`

---

# Automatic Sync

GuildCrafts synchronizes recipe data automatically between addon users.

* no setup required  
* low chat traffic  
* new recipes broadcast automatically  
* only one guild member ever responds to `!gc` — even when multiple addon users are online or some are inside dungeons/battlegrounds

Members who leave the guild are automatically removed after 30 days.

Works best when multiple guild members use the addon — the more players sync, the more complete the database becomes.

***

## Project Status

GuildCrafts is now considered **feature complete** for its original scope.

The core problem the addon was created to solve — helping guild members quickly discover who can craft an item — has been solved, and the addon has reached a stable state.

From this point on, GuildCrafts will move into **maintenance mode**.

This means:

• No new features are currently planned  
• Critical bug fixes may still be addressed  
• Contributions and new maintainers are welcome if the community wants to build on it further

If no new maintainers step forward, the addon will remain available in its current form.