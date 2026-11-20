# GarminSmartwatchKit — experimental

> **Experimental.** Not tested on a Garmin yet. Don't rely on it for treatment decisions.

Garmin (Connect IQ) as a LoopKit `SmartwatchManager` plugin, for hosts such as [Trio](https://github.com/nightscout/Trio) and Loop.

It is derived from Trio's `GarminManager`, `GarminWatchState` and `GarminWatchSettings` (Trio contributors, MIT). The Connect IQ code is Trio's. What changed is where the data comes from: the plugin builds the Garmin watch state only from what it reads from its host (`SmartwatchManagerDelegate`) after `hostDataDidChange`, and keeps its devices and settings in its own `rawState`.

## What it does

- Sends glucose (with 2 h of history for SwissAlpine and the complication app, readings at least 5 minutes apart whatever the CGM), trend, delta, IOB, COB, last loop, temp or scheduled basal, ISF, eventual glucose, sensitivity ratio and target to:
  - a watchface or watch app: Trio, SwissAlpine, or Complication;
  - datafields: Trio, SwissAlpine, LoopGraph, any of them at once. LoopGraph gets the 2 h history too. It isn't on the Connect IQ store, so it is registered under both known app IDs: the public source's sideloaded build (`2e18aaa2…`) and Tai's beta build (`986105b6…`); the one not installed is skipped.
- **Forecast:** each watch app declares in code which forecast keys it reads (`GarminForecastFormat`, on `GarminWatchface` and `GarminDatafield`): the plugin's cone (`forecastDate`, `forecastLow`, `forecastHigh`, 5-minute steps up to 4 h), the format for new watch apps; mountrcg's `predicted`, `predictedMin` and `predictedMax` pairs, which LoopGraph reads; or none, which the published Trio, SwissAlpine and Complication apps declare, as they were built against upstream Trio, which never sent a forecast. The broadcast carries the formats of the chosen apps together; set `GarminForecastFormat.isEnabled` to `false` to send none.
- **Watch commands (off by default),** ported from [Tai](https://github.com/mountrcg/Tai) and its Garmin v1 message format: carbs, overrides and temp targets with *Enable Watch Commands*; bolus and meal bolus also need *Allow Bolus Commands*. The command app (below) sends them; the plugin answers only the app that asked and pushes it the preset list, switches and limits.
  - The plugin refuses a command older than 2 minutes (or more than 60 s ahead of the phone), a watch bolus within 6 minutes of the previous one, a repeated request ID (it gets the first answer again), and anything admitted before a switch was turned off. The 6-minute hold and recent bolus and meal-bolus request IDs are kept across app restarts; if that record can't be read, watch boluses are held for 6 minutes from launch.
  - Trio's 20 % recent-bolus check, which Tai also ran, isn't part of the host API, and Trio's host skips it for watch boluses. Instead, every watch bolus and meal bolus needs a glucose reading from the last 15 minutes, besides the 6-minute watch hold. There is no cap at the host's recommendation: the watch isn't shown it. A meal bolus refused for the hold, its age, a switch or missing glucose logs no carbs; if only the bolus is refused afterwards, the carbs stay logged. Without a pump, the watch is told bolus is off.
  - One command app at a time (from mountrcg's Trio PR series): Complication when it is the watchface and Send to Watchface is on, otherwise Trio-WatchControls while commands are on. Only its commands run and only it gets the preset list; it is told when it becomes or stops being the command app (`ownerMode`), and changing it cancels pending commands.
  - **While commands are off (the default), the watch apps get only state**, as from Trio without these changes: no ownerMode notices, no preset pushes and no answer to a preset request. A stand-down notice goes only to an app that was told it was active; a missed one is sent again on the next delivery, reconnect or message from that app, also after a restart.
  - The host applies its own limits (maximum bolus and maximum carbs, and Trio's maximum IOB) and rounds the bolus.
- Settings: watches (chosen in Garmin Connect), watch apps, datafields, commands, display values and glucose colours.
- Logs go to the host's device log.

## Using it

- **Frameworks:** `GarminSmartwatchKit` and `GarminSmartwatchKitUI`, for hosts that link plugins (Trio).
- **Plugin bundle:** `GarminSmartwatchPlugin.loopplugin`, for hosts that load plugin bundles (Loop). Loop's Garmin and personal builds load it and offer it in Add Watch like any watch.
- **Dependencies:** LoopKit and LoopKitUI (the `next-dev` API, as Loop and Trio since #1718 use) from the host's workspace, and Garmin's [Connect IQ SDK](https://github.com/garmin/connectiq-companion-app-sdk-ios) (Swift package).
- **Host app:** needs a URL scheme (Garmin Connect calls back with the chosen watches; the host passes that URL to `hostDidReceiveURL`) and `LSApplicationQueriesSchemes` for Garmin Connect (`gcm-ciq`), as Trio and Loop's Garmin and personal branches have.

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`; the generated project is committed.

## Screenshot

Until 2026-11-09 Loop's personal build listed Garmin as coming soon, as below; it now offers Garmin like any watch:

<img src="docs/loop-add-watch-coming-soon.png" width="220" alt="Loop's Add Watch: Pebble, and Garmin marked Coming soon">

## Licence

MIT. See `LICENSE`, which keeps Trio's copyright notice.
