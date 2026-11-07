// Builds the previews from the template by injecting the OpenStreetMap city data.
//   nearby-live-preview.html  – neon 3D map, self-contained (published as the artifact)
//   satellite/index.html      – same scene on live satellite imagery (local preview: node serve.js)
// Usage: node src/build.js
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const template = fs.readFileSync(path.join(__dirname, 'template.html'), 'utf8');
const city = fs.readFileSync(path.join(root, 'city-old-delhi.json'), 'utf8');

const page = template.replace('__CITY__', () => city);
fs.writeFileSync(path.join(root, 'nearby-live-preview.html'), page);

const sat = page.replace('<script src="https://cdnjs', () => '<script>window.NL_SATELLITE=true</script>\n<script src="https://cdnjs');
fs.mkdirSync(path.join(root, 'satellite'), { recursive: true });
fs.writeFileSync(path.join(root, 'satellite', 'index.html'), sat);
console.log('built', (page.length / 1024).toFixed(0) + ' KB x2');
