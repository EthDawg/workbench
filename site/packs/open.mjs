// The repository is in the URL fragment, so it is not sent to the website server.
export function packLink(hash) {
  const fields = new URLSearchParams(hash.replace(/^#/, ''));
  if ([...fields].length !== 1 || !fields.has('source')) return null;
  const source = fields.get('source');
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$/.test(source) || source.includes('..')) return null;
  return { source, url: `workbench://packs/add?source=${encodeURIComponent(`https://github.com/${source}`)}` };
}
if (typeof document !== 'undefined') {
  const pack = packLink(location.hash);
  if (pack) {
    document.querySelector('#source').textContent = pack.source;
    const link = document.querySelector('#open'); link.href = pack.url; link.hidden = false;
  } else {
    document.querySelector('#problem').textContent = 'Ask your team for its pack link, or paste the private GitHub repository address into Packs in Workbench.';
  }
}
