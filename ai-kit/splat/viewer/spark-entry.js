// three.js r180 + Spark (World Labs' Gaussian-splat renderer for three.js, MIT) in one ES module,
// so the splat viewer works offline inside a single HTML file. Rebuild (see README):
//   npm i three@0.180.0 @sparkjsdev/spark@2.3.1 esbuild && npx esbuild ai-kit/splat/viewer/spark-entry.js \
//     --bundle --minify --format=esm --outfile=ai-kit/splat/viewer/spark.bundle.min.js
export * from 'three'
export { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js'
export { SparkRenderer, SplatMesh } from '@sparkjsdev/spark'
