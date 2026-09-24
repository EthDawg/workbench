import release from './updates/preview.json' with { type: 'json' };
export const currentRelease = Object.freeze(release);
export function renderPublishedRelease(html, value = currentRelease) {
  if (!/^v[0-9]+\.[0-9]+\.[0-9]+-preview\.[0-9]+$/.test(value.tag) ||
      value.download_url !== `https://github.com/EthDawg/workbench/releases/download/${value.tag}/Workbench.Preview.zip`) throw new Error('Invalid Preview release record');
  return html.replaceAll('{{PREVIEW_TAG}}', value.tag)
    .replaceAll('{{PREVIEW_VERSION}}', `${value.version} Preview ${value.tag.split('.').at(-1)}`)
    .replaceAll('{{UPDATE_INSTALL_NOTE}}', value.feed_url
      ? 'After this one-time manual installation, Settings → Workbench updates keeps this edition current. Scheduled updates show a quiet reminder and wait for your work.'
      : 'Future Preview updates keep that copy.');
}
