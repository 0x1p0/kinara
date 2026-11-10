// Every word on the site lives here. Entries marked `placeholder: true` must be replaced
// before launch.
import releaseFile from './release.json';

/** The newest release's disk image when the site was built (scripts/latest-release.mjs), or null. */
export const release = releaseFile as { version: string; url: string; bytes: number } | null;

export const site = {
  name: 'Kinara',
  url: process.env.NEXT_PUBLIC_SITE_URL ?? 'https://kinara-app.pages.dev',
  maker: '0x1p0',
  tagline: 'The edges of your trackpad, as controls.',
  description:
    'Kinara turns the edges and corners of your Mac trackpad into controls: volume, brightness, a one-finger clipboard, a fader for every app and 53 actions.',
  license: 'MIT License',
  requirements: 'macOS 13 or later. Apple silicon and Intel.',
  // Apple asks for this credit wherever its marks are named; keep the list to the ones the site uses.
  trademarks:
    'Apple, Mac, MacBook, macOS, Magic Trackpad, Safari, FaceTime, AirPods and Mission Control are trademarks of Apple Inc., registered in the U.S. and other countries and regions. Kinara is an independent app and is not affiliated with, sponsored or endorsed by Apple Inc.',
  sourceUrl: 'https://github.com/0x1p0/kinara',
  // Download fetches the disk image itself; one universal build runs natively on every Mac.
  downloadUrl: release?.url ?? 'https://github.com/0x1p0/kinara/releases/latest',
  releasesUrl: 'https://github.com/0x1p0/kinara/releases',
  issuesUrl: 'https://github.com/0x1p0/kinara/issues',
  email: 'support@kinara.example', // placeholder: true
  updated: '10 November 2026',
};

export const hero = {
  eyebrow: 'Kinara',
  title: 'Your trackpad. Now with edges.',
  lead: 'A one-finger clipboard, a fader for every app and 53 shortcuts. All from the edges you never touch.',
  price: 'Free and open source. macOS 13 or later.',
  hint: 'Drag an edge or tap a corner.',
};

/** The pinned scroll story under the hero: one caption per beat, in order. */
export const story = [
  { title: 'Double‑tap. Slide. Lift.', sub: 'Your recent copies, pictures too, are one corner away. Type to find one.' },
  { title: 'Turn one app down.', sub: 'The edge lowers only the app in front. Everything else keeps playing.' },
  { title: 'And the basics, perfected.', sub: 'Volume on the right. Brightness on the left, and the screen follows.' },
  { title: 'Corners do the rest.', sub: 'Paste, Mission Control or any of 53 actions, and every app can have its own.' },
];

/** What each corner of the hero trackpad does when tapped. */
export const padCorners = [
  { id: 'tl', label: 'Mission Control', how: 'Top-left corner' },
  { id: 'tr', label: 'Paste', how: 'Top-right corner' },
  { id: 'bl', label: 'Show desktop', how: 'Bottom-left corner' },
  { id: 'br', label: 'Clipboard history', how: 'Bottom-right corner' },
] as const;

/** "Get the highlights": clips cut from the Kinara film. */
export const highlights = [
  { id: 'clipboard', title: 'Clipboard history.', body: 'Double-tap a corner and slide through your recent copies, pictures included, or just type to find one. Lift to paste.' },
  { id: 'corners', title: 'Corners that do things.', body: 'Double-tap or tap and hold. One finger is enough.' },
  { id: 'aware', title: 'It knows a palm from a finger.', body: 'Every touch is checked for intent, and every app can have its own edges.' },
  { id: 'mixer', title: 'A fader for every app.', body: 'Mute one, solo one, and calls lower everything else.' },
  { id: 'feel', title: 'Feels built in.', body: 'Fine control, speed-sensitive steps and haptics up to Strongest.' },
];

export const mixer = {
  eyebrow: 'Mixer',
  title: 'Every app gets its own fader.',
  lead: 'Turn one app down without touching the rest, right from the menu bar.',
  points: [
    { title: 'Solo a call.', body: 'Silence everything except the app you’re talking in.' },
    { title: 'Calls lower the rest.', body: 'When an app uses the microphone, everything else fades to the level you set.' },
    { title: 'Boost to 150 percent.', body: 'Make a quiet video louder without touching the system volume.' },
    { title: 'Send it anywhere.', body: 'Music to your AirPods while the call stays on the speakers.' },
  ],
  note: 'The mixer needs macOS 14.2 or later. Audio is adjusted as it plays and never recorded.',
};

/** The audio picker, inside the mixer section. */
export const audioApps = {
  eyebrow: 'Audio apps',
  title: 'Mute any app from a corner.',
  lead: 'Double-tap a corner and every app making sound is right there. Slide to one, lift, and it goes quiet.',
  points: [
    { title: 'Slide right for only this.', body: 'Everything else goes quiet, so a call or a song plays alone.' },
    { title: 'See what’s playing.', body: 'Each app shows whether it’s playing, muted or waiting, with live levels.' },
    { title: 'Undo just as fast.', body: 'Muted apps stay in the list, one lift from playing again.' },
  ],
};

/** The little things: a live Mac screen that answers taps the way Kinara does (corner glass,
 * corner light, edge light, rest preview, undo), with its notes. Timings come from the app. */
export const touches = {
  eyebrow: 'Little things',
  title: 'Answered in the corner you tapped.',
  lead: 'A tap draws one piece of glass out of the matching corner of your screen. It names the action, shows what happened and slips back. Try it here.',
  hint: {
    pointer: 'Click a corner twice. Hover on one to preview it. Move along an edge.',
    touch: 'Tap a corner twice. Touch and hold one to preview it. Drag along an edge.',
  },
  /** Captions for what the visitor just did. */
  states: {
    idle: { title: 'Try it on this screen.', body: '' },
    armed: { title: 'First tap.', body: 'A glass bead and a faint light in that corner. Tap again within half a second.' },
    fired: { title: 'Second tap.', body: 'The bead stretches into a pill naming the action, the light runs out from the corner and the trackpad ticks twice.' },
    undone: { title: 'Undone.', body: 'The same tap within 2 seconds puts things back.' },
  },
  /** The guided loop, one chapter per little thing. */
  chapters: [
    { id: 'tap', label: 'Double-tap', title: 'Tap once, then again.', body: 'The first tap draws a bead and a faint light. The second stretches the bead into a pill naming the action, and the song that started lands in the same pill.' },
    { id: 'rest', label: 'Rest', title: 'Rest to preview.', body: 'Keep a finger still on a corner and its pill shows what the taps do. Nothing runs until you tap.' },
    { id: 'undo', label: 'Undo', title: 'Do it again to undo.', body: 'The same tap within 2 seconds puts things back. Mission Control closes, a mute lifts, a paste comes back out.' },
    { id: 'slide', label: 'Edge light', title: 'A light that follows you.', body: 'Slide along an edge and a soft light runs down that side of the screen, right beside your finger.' },
  ],
  demo: {
    label: 'A Mac screen that answers taps the way Kinara does',
    corners: {
      tl: { name: 'Top-left corner', action: 'Mission Control', icon: 'mission', hold: '' },
      tr: { name: 'Top-right corner', action: 'Play / pause', icon: 'playpause', hold: 'Show edge map' },
      bl: { name: 'Bottom-left corner', action: 'Mute app in front', icon: 'muteapp', hold: '' },
      br: { name: 'Bottom-right corner', action: 'Show desktop', icon: 'desktop', hold: 'Lock screen' },
    },
    edges: { left: 'Left edge, slide', right: 'Right edge, slide' },
    tapLabel: 'double-tap',
    doubleTap: 'Double-tap',
    tapHold: 'tap and hold',
    settings: 'change it in Settings',
    again: 'Double-tap again to undo',
    undone: 'Undone',
    muted: 'Safari muted',
    unmuted: 'Safari unmuted',
    track: 'Night Drive',
    artist: 'Neon Coast',
    playing: 'Playing',
    paused: 'Paused',
    chapters: 'Little things to try',
    play: 'Play the little things',
    pause: 'Pause the little things',
    /** Decorative words on the mock screen. */
    menu: ['Safari', 'File', 'Edit', 'View', 'History', 'Window'],
    clock: 'Mon 9:41',
    tab: 'Golden hour, 4K',
  },
  points: [
    { title: 'One piece of glass.', body: 'The first tap draws a bead in the matching corner of your screen. The second stretches it into a pill naming the action.' },
    { title: 'Results land in the pill.', body: '“Safari muted” or the song that started, right where you tapped. Nothing else pops up.' },
    { title: 'Rest to preview.', body: 'Keep a finger still on a corner to see what its taps do. Nothing runs until you tap.' },
    { title: 'Repeat to undo.', body: 'Do the same tap within 2 seconds and things go back: a mute, Mission Control, even a paste.' },
    { title: 'Light where you touch.', body: 'A faint light answers a first tap and a bright one the second. Slide along an edge and a soft one follows your finger.' },
    { title: 'Ticks you can feel.', body: 'The trackpad ticks twice when a tap fires, so you know it worked without looking.' },
    { title: 'It says where to change it.', body: 'The first time a corner fires, a second line names the spot and where to change it. After that, how to undo.' },
    { title: 'A tour that waits for you.', body: 'The first run shows each gesture on your screen beside a small trackpad, and moves on when you do it.' },
  ],
  note: 'Prefer the usual indicator? Tap feedback can show in the corner or in the indicator, and the edge and corner light can be turned off, both in Settings.',
};

/** The details grid. `stat` tiles lead with a big number; `size` is the column span out of 6. */
export const details = {
  title: 'Built like it came with your Mac.',
  tiles: [
    { stat: '53', title: 'actions', body: 'Any of them on any edge or corner, and a different set for every app.', size: 4 },
    { stat: '0.014%', title: 'CPU at rest', body: 'Measured on an M4 MacBook with gestures paused and the menu closed.', size: 2 },
    { stat: '11.6 MB', title: 'of memory', body: 'Same Mac, same measurement.', size: 2 },
    { stat: '50%', title: 'notch', body: 'Turn it on and levels pause at the middle, or at your favorite, with a tap you can feel.', size: 2 },
    { stat: '60%', title: 'headphone limit', body: 'Give each output its own ceiling. Speakers can still go to 100.', size: 2 },
    { stat: '2 s', title: 'to undo', body: 'Repeat a tap within 2 seconds and it puts things back, whether it muted an app or opened Mission Control.', size: 3 },
    { stat: '0.7 s', title: 'to preview', body: 'Rest a finger on a corner that long and its pill shows what the taps do, without doing it.', size: 3 },
    { stat: 'Strongest', title: 'haptics', body: 'From the trackpad’s own actuator: a tick for each step, and two when a tap fires.', size: 3 },
    { stat: '0', title: 'analytics', body: 'No tracking. Clipboard history lives in memory and leaves when you quit.', size: 3 },
  ],
};

/** The download section: what open source means here. */
export const download = {
  title: 'Kinara for Mac.',
  price: 'Free.',
  priceNote: 'Open source, for good.',
  points: [
    { title: 'Free, every feature', body: 'No trial, no account and no ads. Nothing to unlock.' },
    { title: 'Open source', body: `Read every line on GitHub, under the ${site.license}.` },
    { title: 'Signed updates', body: 'Installed only when you say so, from the same releases.' },
  ],
  note: `Kinara is free and open source under the ${site.license}.`,
  // Under the button: what the file is, and the one step macOS asks for the first time.
  meta: release ? `Version ${release.version} · ${(release.bytes / 1e6).toFixed(1)} MB · Universal: Apple silicon and Intel` : 'Universal: Apple silicon and Intel',
  firstLaunch: 'First launch: open System Settings, then Privacy & Security, and click Open Anyway.',
};

export const questions = [
  { q: 'Which Macs does it work with?', a: 'Any Mac with a built-in or Magic Trackpad on macOS 13 or later, Apple silicon or Intel. There is one download for both: it runs natively on either. The per-app mixer needs macOS 14.2.' },
  { q: 'Why does macOS ask before it opens the first time?', a: 'Kinara is signed but not yet notarized by Apple, so macOS asks once. Open System Settings, then Privacy & Security, and click Open Anyway. After that it opens like any other app, and updates keep it that way.' },
  { q: 'Will it get in the way of normal use?', a: 'The middle of the trackpad stays yours. Edges answer only a deliberate swipe that starts at the edge, and palm protection checks every touch.' },
  { q: 'How do I know a tap worked?', a: 'A glass pill grows out of the matching corner of your screen and names the action, and the trackpad ticks twice. Results such as “Safari muted” or the song that started appear in the same pill. If you prefer, Settings can show them in the indicator instead.' },
  { q: 'What if I tap a corner by mistake?', a: 'Do the same tap again within 2 seconds and it’s undone. To check a corner first, rest a finger on it: its pill shows what the taps do without running anything.' },
  { q: 'Why did play do nothing in Safari?', a: 'macOS sometimes puts a background Safari tab to sleep, and a sleeping tab misses the play command. Kinara tells you when that happens, and the next press opens Safari so the tab wakes and catches up.' },
  { q: 'Does Kinara show in the Dock?', a: 'Only while one of its windows is open, such as Settings, so ⌘-Tab can find it. The rest of the time it stays in the menu bar.' },
  { q: 'Can it keep pictures, and how many copies?', a: 'Yes. Screenshots and copied pictures sit beside your text and paste back exactly as you copied them. Keep 10, 20, 50 or 100 copies, or leave pictures out, in Settings. When the picker opens, just type to find one, and ⌘1 to ⌘9 paste the first nine.' },
  { q: 'Does it record anything?', a: 'No. Clipboard history lives in memory and is gone when you quit, audio is never recorded or saved, and there are no analytics.' },
  { q: 'Is it really free?', a: `Yes, every feature, for good. Kinara is open source under the ${site.license}: no trial, no account and no ads.` },
  { q: 'Where is the source code?', a: 'On GitHub, with the releases, the tests and the notes on how each release is built and signed. Bug reports, ideas and pull requests are welcome there.' },
];

export const legal = {
  privacy: {
    title: 'Privacy',
    intro: 'Kinara is built to know as little about you as possible. This page explains what the app and this website handle.',
    sections: [
      { h: 'On your Mac', p: ['Kinara reads your trackpad to recognise gestures. Touches are processed on your Mac and never leave it.', 'Clipboard history, text and pictures alike, is kept in memory only, is never written to disk, and skips anything a password manager marks as private.', 'The mixer routes an app’s sound only to play it back at the level you chose. Audio is never recorded, saved or sent.'] },
      { h: 'Network', p: ['Kinara checks GitHub for signed updates once a day. That request includes your app version and, like any request, your IP address, and GitHub’s own privacy statement covers it. You can turn update checks off in Settings.', 'Kinara has no account, no sign-in and no license check, so nothing else is sent.'] },
      { h: 'Open source', p: ['You don’t have to take this page on trust: Kinara’s source code is public, so anyone can check what it does.'] },
      { h: 'This website', p: ['This site uses no analytics, no advertising and no cookies. Your theme choice is saved in your own browser. Our host keeps standard server logs.'] },
      { h: 'Contact', p: [`Questions about privacy: ${site.email}.`] },
    ],
  },
  license: {
    title: 'License',
    intro: `Kinara is free and open source under the ${site.license}. You can use it, read it, change it and share it, as the license below sets out.`,
    sections: [
      { h: 'In short', p: ['Use Kinara on as many Macs as you like, for anything. Read the source, change it, and share your own copies, changed or not, as long as they keep the copyright notice and this license.', 'Kinara comes as it is, with no warranty. It uses parts of macOS that Apple can change, and an update to macOS can stop some of it working until Kinara catches up.'] },
      { h: 'MIT License', p: [
        'Copyright (c) 2026 0x1p0',
        'Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:',
        'The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.',
        'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.',
      ] },
      { h: 'Third-party software', p: ['Kinara includes Sparkle, for updates, under its own MIT License. Its license text ships inside the app as Sparkle-LICENSE.txt.'] },
      { h: 'Contact', p: [`Questions about the license: ${site.email}, or open an issue on GitHub.`] },
    ],
  },
};
