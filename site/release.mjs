// Build-time release selection. The browser receives only the selected, validated
// record in a generated release.mjs, so its report and the HTML agree exactly.
import preview from './updates/preview.json' with { type: 'json' };

const releases = 'https://github.com/EthDawg/workbench/releases';
// The site's public address. Every absolute link the pages carry (canonical, share
// card, sitemap) comes from here, so a domain move is one edit plus the feed decision.
export const siteOrigin = 'https://workbench-mac.vercel.app';
const feeds = `${siteOrigin}/updates`;

export function validateRelease(value, expectedChannel) {
  const match = /^v([0-9]+\.[0-9]+\.[0-9]+)(?:-preview\.([0-9]+)|\+([0-9]+(?:\.[0-9]+)*))?$/.exec(value?.tag);
  const channel = match?.[2] === undefined ? 'production' : 'preview';
  const archive = channel === 'production' ? 'Workbench.zip' : 'Workbench.Preview.zip';
  if (!match || value.version !== match[1] || (expectedChannel && channel !== expectedChannel) ||
      (value.channel && value.channel !== channel) ||
      (match?.[3] !== undefined && match[3] !== value.build) ||
      !/^[0-9]+(?:\.[0-9]+)*$/.test(value.build) ||
      !/^[0-9a-f]{40}$/.test(value.source) || !/^[0-9a-f]{64}$/.test(value.sha256) ||
      value.download_url !== `${releases}/download/${value.tag}/${archive}` ||
      (value.feed_url !== undefined && value.feed_url !== `${feeds}/${channel}.xml`) ||
      (value.feed_url !== undefined && !/^[0-9a-f]{64}$/.test(value.feed_sha256)) ||
      (channel === 'production' && (value.channel !== channel || !value.feed_url))) {
    throw new Error('Invalid published release record: version, edition, archive and feed must agree');
  }
  return Object.freeze({ ...value, channel });
}

export function selectPublicRelease({ production, preview }, { requireProduction = false } = {}) {
  if (production !== undefined) return validateRelease(production, 'production');
  if (requireProduction) throw new Error('Production promotion requires a verified production.json and signed production.xml');
  return validateRelease(preview, 'preview');
}

let production;
try {
  production = (await import('./updates/production.json', { with: { type: 'json' } })).default;
} catch (error) {
  // A malformed production record must stop the build, never fall back to Preview.
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
}
export const currentRelease = selectPublicRelease({ production, preview });

export function renderPublishedRelease(html, record = currentRelease) {
  const value = validateRelease(record);
  const isPreview = value.channel === 'preview';
  const name = isPreview ? 'Workbench Preview' : 'Workbench';
  const version = isPreview ? `${value.version} Preview ${value.tag.split('.').at(-1)}` : value.version;
  const tokens = {
    SITE_ORIGIN: siteOrigin,
    RELEASE_NAME: name,
    RELEASE_TAG: value.tag,
    RELEASE_VERSION: version,
    RELEASE_URL: `${releases}/tag/${value.tag}`,
    DOWNLOAD_URL: value.download_url,
    CHECKSUM_URL: `${releases}/download/${value.tag}/SHA256SUMS.txt`,
    APP_BUNDLE: `${name}.app`,
    APP_DATA_DIRECTORY: name,
    RELEASE_STATUS: isPreview ? 'Try it. Help shape what’s next.' : 'Small tools. Useful moments.',
    RELEASE_NOTICE: isPreview
      ? 'The current public download is a signed and notarized Preview. A Workbench production release will replace this link only after its package and update feed are verified.'
      : 'Speak a thought. Capture a detail. Keep a good idea moving. This download is Developer ID signed and notarized by Apple.',
    RELEASE_INSTALL_CONTEXT: isPreview
      ? 'Your earlier Voice and StageMark data stays in place. Workbench imports a separate copy for this Preview.'
      : 'Workbench and Workbench Preview keep separate libraries and settings. Installing Workbench does not copy Preview data automatically.',
    RELEASE_DATA_NOTE: isPreview
      ? 'After checking that your saved work is available in Workbench Preview, you can remove older Voice and StageMark apps from Applications. Keep their saved-data folders.'
      : 'Keep your Preview installation and saved-data folders until you have checked the work you need in Workbench. Replacing the app preserves this edition’s saved work.',
    UPDATE_INSTALL_NOTE: value.feed_url
      ? 'After this one-time manual installation, Settings → Workbench updates keeps this edition current. An update waits to restart until your active work finishes.'
      : 'Future Preview updates keep that copy.',
    UPDATE_QUICK_START: value.feed_url
      ? 'Open Settings → Workbench updates in the app to review the next update. Your saved work stays with you. Versions without the updater need one manual replacement first.'
      : 'This version has no automatic updater. Quit the app and replace it in the same Applications folder with the next Preview download.',
    UPDATE_DETAILS: value.feed_url
      ? 'Use Settings → Workbench updates to check for a new version. Automatic checks and background downloads are on by default; both can be changed in Settings, and existing choices are retained. A downloaded update can install on normal Quit or when you explicitly restart an idle app. Active work defers an update-triggered restart. Versions without the updater need one manual replacement first.'
      : 'This published version has no automatic updater. To update, quit Workbench Preview and replace the existing app in the same Applications folder with the next Preview download.',
    // Temporary aliases keep independently edited guide pages compatible.
    PREVIEW_TAG: value.tag,
    PREVIEW_VERSION: version
  };
  return html.replace(/\{\{([A-Z_]+)\}\}/g, (token, key) => {
    if (!Object.hasOwn(tokens, key)) throw new Error(`Unknown release placeholder: ${token}`);
    return tokens[key];
  });
}
