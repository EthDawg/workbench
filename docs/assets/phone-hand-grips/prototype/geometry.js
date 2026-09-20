/* Top-left coordinates. Input images retain their full source canvas. */
function gripGeometry({right,bottom,height,aspect,border,corners,sourcePhone,sourceSize}) {
  const bezel=height*border, screenHeight=height-2*bezel;
  const width=screenHeight*aspect+2*bezel;
  const outer={x:right-width,y:bottom-height,width,height};
  const screen={x:outer.x+bezel,y:outer.y+bezel,width:width-2*bezel,height:screenHeight};
  const [sx,sy,sw,sh]=sourcePhone, scale=height/sh;
  return {outer,screen,bezel,innerRadius:screen.width*corners,outerRadius:screen.width*corners+bezel,scale,
    palm:{x:right-(sx+sw)*scale,y:bottom-(sy+sh)*scale,width:sourceSize[0]*scale,height:sourceSize[1]*scale},
    fingers:{x:outer.x-sx*scale,y:bottom-(sy+sh)*scale,width:sourceSize[0]*scale,height:sourceSize[1]*scale}};
}
if(typeof module!=='undefined')module.exports={gripGeometry};
