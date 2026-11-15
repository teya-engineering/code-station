# Project site

The public page for Teya Code Station, served by GitHub Pages at
<https://teya-engineering.github.io/code-station/>.

This branch holds nothing but the site. It is an orphan branch with no history in
common with `main`, so it is a deploy target rather than something to merge or
rebase. Pages serves it from the branch root.

Everything is static, with no build step. `index.html` is the whole page, with its
CSS and JavaScript inline. `.nojekyll` keeps Pages from running the files through Jekyll.

The page is a scroll tour of the eight parts of the Code Station talk. Each part is a
scene drawn in HTML and driven by scroll, so there are no screenshots to keep in step
with the app. Add `?at=mcp:0.6` to the address to open a part some of the way through,
which helps when reviewing or taking screenshots.

Nothing is loaded from another site. Check that this stays true after a change.

## Assets

`assets/fonts/Figtree-*.ttf` are the four weights of Figtree the page uses, served
from here so the page makes no request to a font host.

`assets/mark.svg` is the app icon redrawn as vector, and `assets/icon-512.png` is
the same mark from `Resources/AppIcon.icns` for the Apple touch icon.

`assets/og.jpg` is the social card.

The colours in `index.html` come from `Sources/MenuBarApp/Theme.swift` on `main` and
from the project colour wheel in the talk, so the page, the talk and the app read as
one system.
