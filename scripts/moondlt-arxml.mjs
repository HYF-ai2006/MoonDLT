#!/usr/bin/env node
import { closeSync, fstatSync, openSync, readSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = dirname(dirname(fileURLToPath(import.meta.url)));

function readBounded(path, maximum) {
  const fd = openSync(path, 'r');
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > maximum) throw new Error('input is not a file or exceeds size limit');
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < buffer.length) {
      const n = readSync(fd, buffer, offset, buffer.length - offset, offset);
      if (n === 0) throw new Error('short input read');
      offset += n;
    }
    const after = fstatSync(fd);
    if (after.size !== stat.size || after.mtimeMs !== stat.mtimeMs) {
      throw new Error('input changed while reading');
    }
    return buffer;
  } finally {
    closeSync(fd);
  }
}

async function main() {
  const [catalogPath, framePath, framing = 'storage', ...extra] = process.argv.slice(2);
  if (!catalogPath || !framePath || extra.length || !['storage', 'network', 'serial'].includes(framing)) {
    throw new Error('Usage: node scripts/moondlt-arxml.mjs CATALOG.json RECORD.dlt [storage|network|serial]');
  }
  const metadata = new TextDecoder('utf-8', { fatal: true }).decode(readBounded(catalogPath, 8 * 1024 * 1024));
  const frame = readBounded(framePath, 65551);
  const build = spawnSync(process.platform === 'win32' ? 'moon.exe' : 'moon',
    ['build', 'cmd/arxml', '--target', 'js', '--deny-warn'], { cwd: root, encoding: 'utf8' });
  if (build.error) throw build.error;
  if (build.status !== 0) throw new Error(build.stderr || build.stdout);
  const moduleUrl = pathToFileURL(join(root, '_build/js/debug/build/cmd/arxml/arxml.js')).href;
  const library = await import(moduleUrl);
  const result = JSON.parse(library.decode_arxml_record(metadata, new Uint8Array(frame), framing));
  if (!result.success) throw new Error(result.error);
  process.stdout.write(JSON.stringify(result.value, null, 2) + '\n');
}

main().catch(error => {
  process.stderr.write(error.message + '\n');
  process.exitCode = 1;
});
