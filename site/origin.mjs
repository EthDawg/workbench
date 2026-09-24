// The one place that names the website's addresses. Everything the site says
// about itself (canonical links, the agent brief, the handbook's own pages)
// derives from these, so moving the site is a one-line change. HOSTING.md owns
// the reasoning; site/tests/origin.test.mjs keeps every other file address-free.

// Where people should find the site. This moves to https://workbench.mwdm.cloud
// once that domain is verified on the existing Vercel project.
export const SITE_ORIGIN = 'https://workbench-mac.vercel.app';

// Where installed apps and store listings already point: the update feed,
// the privacy policy and every link compiled into a shipped build. It is
// served by the same deployment as SITE_ORIGIN, and it never moves.
export const DURABLE_ORIGIN = 'https://workbench-mac.vercel.app';

export const siteURL = path => new URL(path, SITE_ORIGIN).href;

// The path a published file answers on: index.html is served as its directory.
export const pagePath = file => '/' + file.replace(/(^|\/)index\.html$/, '$1');

export function withCanonical(html, path) {
  if (/rel=["']canonical["']/i.test(html)) throw new Error(`${path} already declares a canonical link`);
  const parts = html.split('</head>');
  if (parts.length !== 2) throw new Error(`${path} needs exactly one </head>`);
  return `${parts[0]}  <link rel="canonical" href="${siteURL(path)}">\n</head>${parts[1]}`;
}
