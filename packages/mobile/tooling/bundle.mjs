import {build} from 'esbuild';
import path from 'node:path';
const [register, entry, output, config] = process.argv.slice(2);
await build({
  stdin: {contents:`import ${JSON.stringify(path.resolve(register))};\nimport ${JSON.stringify(path.resolve(config))};\nimport ${JSON.stringify(path.resolve(entry))};`,
          resolveDir:process.cwd(), sourcefile:'flux-mobile-entry.js', loader:'js'},
  bundle:true, format:'esm', platform:'browser', target:['es2022'],
  outdir:path.dirname(path.resolve(output)), entryNames:path.basename(output, '.js'), splitting:true, chunkNames:'chunks/[name]-[hash]',
  sourcemap:false, logLevel:'warning', metafile:false,
});
