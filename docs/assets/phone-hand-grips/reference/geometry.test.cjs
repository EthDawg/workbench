const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');
const {gripGeometry}=require('../prototype/geometry.js');
const m=JSON.parse(fs.readFileSync(path.join(__dirname,'../manifest.json')));
const near=(a,b)=>assert.ok(Math.abs(a-b)<1e-8,`${a} != ${b}`);let count=0;
for(const v of m.variants)for(const aspect of [.43,.50,.565])for(const border of [.004,.009,.025])for(const height of [650,730,810])for(const corners of [.03,.16]){
 const input={right:900,bottom:835,height,aspect,border,corners,sourcePhone:v.sourcePhone,sourceSize:v.size};
 const g=gripGeometry(input),[x,y,w,h]=v.sourcePhone;
 near(g.outer.x+g.outer.width,900);near(g.outer.y+g.outer.height,835);
 near(g.palm.x+(x+w)*g.scale,900);near(g.palm.y+(y+h)*g.scale,835);
 near(g.fingers.x+x*g.scale,g.outer.x);near(g.fingers.y+(y+h)*g.scale,835);
 near(g.palm.width/v.size[0],g.palm.height/v.size[1]);near(g.fingers.width/v.size[0],g.fingers.height/v.size[1]);
 near(g.screen.width/g.screen.height,aspect);assert.ok(g.screen.x>g.outer.x&&g.screen.y>g.outer.y);
 // Widening changes finger translation, never palm placement or either scale.
 const wider=gripGeometry({...input,aspect:aspect+.01});near(g.palm.x,wider.palm.x);near(g.scale,wider.scale);
 near(wider.fingers.x-g.fingers.x,wider.outer.x-g.outer.x);count++;
}
console.log(`${count} geometry cases passed: both edge contacts, aspect, bezel inset, uniform hand scale, and fixed right/bottom anchor.`);
