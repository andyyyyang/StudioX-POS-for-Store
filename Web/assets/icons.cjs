// POS 多用到的 Heroicons（@heroicons/react 24/outline，和後台、StudioX Console App 同一套），輸出成 asset catalog 的向量圖示（template）。
// Console App 已經有的那一批是照抄過來的（StudioX-Console-App 的 Web/assets/icons.cjs）；這裡只產生 POS 才用的。
// 用法（在 atelier-cms 裝好套件之後）：NODE_PATH=../atelier-cms/node_modules node Web/assets/icons.cjs StudioXPOS/Assets.xcassets/Icons
const fs = require('fs'), path = require('path')
const React = require('react')
const { renderToStaticMarkup } = require('react-dom/server')
const out = process.argv[2]
const names = `Fire QrCode Calculator UserGroup Minus ArrowLeft Wifi Signal Scissors Map Cake ArrowsPointingOut Backspace CircleStack
Cloud ServerStack CurrencyDollar ArchiveBox ShoppingCart TableCells NoSymbol PlusCircle MinusCircle ViewColumns Square3Stack3D
SpeakerWave Beaker BookmarkSquare Bars2`.split(/\s+/).filter(Boolean)
const kebab = (s) => s.replace(/([a-z])([A-Z0-9])/g, '$1-$2').replace(/([0-9])([A-Z])(?![0-9])/g, '$1-$2').replace(/([A-Z])([A-Z][a-z])/g, '$1-$2').toLowerCase()
for (const n of names) {
  const Icon = require(`@heroicons/react/24/outline/${n}Icon.js`)
  let svg = renderToStaticMarkup(React.createElement(Icon, { width: 24, height: 24 }))
  svg = svg.replace(/currentColor/g, '#000000').replace(/ aria-hidden="true"| data-slot="icon"/g, '')
  const name = `hi-${kebab(n)}`
  const dir = path.join(out, `${name}.imageset`)
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, `${name}.svg`), svg + '\n')
  fs.writeFileSync(path.join(dir, 'Contents.json'), JSON.stringify({
    images: [{ filename: `${name}.svg`, idiom: 'universal' }],
    info: { author: 'xcode', version: 1 },
    properties: { 'preserves-vector-representation': true, 'template-rendering-intent': 'template' },
  }, null, 2) + '\n')
}
console.log(names.length, 'icons →', out)
