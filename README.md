# Video Feed — every channel video in one vertical feed (iOS)

A **Video** tab and a **Watch as Feed** action: channel videos full screen, one swipe apart. **Following** shows your
channels' videos newest first, **For You** mixes them with channels Telegram recommends and learns what you like from what
you watch, like and skip. Opened from a chat, the feed plays that chat's videos and round videos, then continues into
For You.

▶︎ [Media/video-feed.mp4](Media/video-feed.mp4) — the feature in the iOS Simulator (1:1).

This is an unofficial change to the open-source [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) client.
It is not affiliated with Telegram.

Pure UIKit and Telegram's own components (glass, context menus, share sheet, video player), no new dependencies, no server
changes. 24 files, +5127 −1: one new module, `VideoFeed` (11 Swift files), and small hooks in 12 existing files.
Built with the project's own `Make.py build` for the simulator (`debug_sim_arm64`).

## How it works

- **Where it opens.**
  - The **Video** tab between Chats and Settings (Following / For You).
  - **Watch as Feed** in the context menu of any video or round video in a chat: the chat's videos, starting from that one.
  - **Watch as Feed** in the shared-media menu of a profile, when the chat has videos.
  - A glass button next to Search in the bottom panel of a channel that has videos.
  - **Settings ▸ Video Feed**.
- **Playback.** Only the page on screen plays (with sound, looped); neighbours show a blurred thumbnail, and the next two
  videos are preloaded so a swipe starts playing at once. Tap pauses, double tap likes with a heart at the finger, hold plays
  at 2×, drag the progress bar to scrub. The sound button mutes the feed without taking the audio session, so music keeps
  playing.
- **The info card.** Avatar and channel name (tap opens the channel), why the video is shown ("Like “Durov's Channel”",
  "Reposted in …", "By hashtag #…"), the date, and **Subscribe** or **View in Chat**. The caption keeps premium emoji,
  quotes and formatting; a long one is cut to two lines and **more** expands it.
- **Side buttons.** Like, Not Interested, and More: Don't Show This Channel, Share (Telegram's share sheet), Save to Saved
  Messages, View in Chat. Forwarding-protected content is never shared or saved.
- **Tabs.** Swipe sideways or tap to switch between Following and For You. Tapping the Video tab again scrolls to the top,
  and on the first video gives a fresh selection. A chat's feed has the chat as a third tab, and scrolling past its last
  video continues into For You.
- **Hiding the tab.** Long-press the Video tab ▸ Hide Video Tab. It comes back from the long-press menu of the Settings tab.

## How For You picks videos

Everything runs on the device from regular API calls (`messages.search` with the video filters, channel recommendations,
`contacts.resolveUsername`, `channels.searchPosts` by hashtag). What the feed learns is stored only on the device; the
server sees ordinary searches and recommendation requests.

- **Sources.** Your channels (from the chat list and the archive, weighted: pinned and recent higher, muted and archived lower)
  and new ones found five ways: Telegram's recommendations for your favourite channels, channels your channels repost,
  channels they mention (`@username`, `t.me/…`), public posts for hashtags you like, and channels similar to discoveries
  you liked.
- **Ranking.** A channel and its best video are picked together by weighted chance: the channel's learned affinity, the
  video's freshness (newer first, 90 days at most), caption topics, engagement (reactions,
  comments and forwards per view), whether it beat the channel's usual views, and format (short and vertical first).
- **Learning.** A full watch or rewatch raises the channel and the caption's words and hashtags, a skip within a second
  lowers them, a like raises them a lot, Not Interested lowers them a lot. On top of that, a short-term interest fades over
  about 20 minutes, three skips in a row make the feed explore more, and a channel watched a lot today steps back until
  tomorrow.
- **Variety.** A channel never repeats within three videos or more than twice per dozen, repeated topics rank lower, and
  roughly every ninth video is exploration. Watched videos are not shown again (also when the same file was reposted).
- **Speed.** The first video appears as soon as two channels have loaded (or after 1.2 s with one); results are cached for
  4 minutes (Following) and 20 minutes (For You), so reopening is instant. Only a few videos are picked ahead, and everything
  after the next video is re-picked after each taste signal.

## Repository

| Path | What |
|---|---|
| `submodules/` | The changed and new files, at their paths in Telegram-iOS. Copy over the repository. |
| `Telegram/` | The English strings (`Localizable.strings`). |
| `video-feed.patch` | The same change as one patch. |
| `Media/video-feed.mp4` | Demo. |

Where the code lives:

| File | What |
|---|---|
| `TelegramUI/Components/VideoFeed/` | **New module.** |
| `…/VideoFeedScreen.swift` | The screen: paging, playback, tabs, gestures, menus, sharing, subscribing. |
| `…/VideoFeedPageNode.swift` | One page: the player of the current video, the blurred thumbnail of the others. |
| `…/VideoFeedInfoCard.swift`, `VideoFeedSideActions.swift`, `VideoFeedTopBar.swift` | The glass card, side buttons and top bar. |
| `…/VideoFeedChatSource.swift` | A chat's feed: videos and round videos merged by date. |
| `…/VideoFeedSmartSource.swift` | Following and For You: channel discovery, loading and ranking. |
| `…/VideoFeedTaste.swift` | What the feed learns, stored on the device per account. |
| `…/VideoFeedItem.swift`, `VideoFeedPlayback.swift`, `VideoFeedTab.swift` | The model, the sound setting, the tab switch. |
| `TelegramRootController.swift` | The Video tab, shown and hidden without restarting. |
| `ChatInterfaceStateContextMenus.swift` | Watch as Feed in the message menu. |
| `PeerInfoScreenDisplayMediaGalleryContextMenu.swift` | Watch as Feed in the shared-media menu. |
| `ChatChannelSubscriberInputPanelNode.swift` | The channel's video feed button. |
| `PeerInfoSettingsItems.swift`, `PeerInfoScreenSettingsActions.swift`, `PeerInfoScreen.swift` | Settings ▸ Video Feed, Show Video Tab. |
| `AccountContext/Sources/UniversalVideoNode.swift` | A convenience initializer, so the module needs no Postbox access. |
| `Localizable.strings`, three `BUILD` files | Strings and the new dependency. |

## Apply

Applies cleanly to [TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) `master`
(279f89e4):

```sh
git apply video-feed.patch
```

or copy `submodules/` and `Telegram/` over the repository. Then build as described in the Telegram-iOS README.

## Limitations

- Ranking is client-side, so For You only knows the channels it can reach from yours. A server-side feed would see far more.
- Likes and Not Interested are local signals for the feed; they are not reactions and nobody sees them.
- Only English strings are added; other languages fall back to them.
- Discovery uses a few dozen ordinary requests when For You opens (cached afterwards), spaced out so they do not hit flood
  limits.

## License

Changes to [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS), published openly so that they can be used under
the terms of the original project.
