// Proxy CORS minimal (Cloudflare Workers, offre gratuite). Ne contourne ni CAPTCHA ni anti-bot.
export default{async fetch(req){const c={'Access-Control-Allow-Origin':'*'};
const t=new URL(req.url).searchParams.get('url');
if(!t||!/^https?:\/\//.test(t))return new Response('paramètre url manquant',{status:400,headers:c});
const h=new URL(t).hostname;
if(/^(localhost|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)/.test(h))return new Response('interdit',{status:403,headers:c});
const r=await fetch(t,{headers:{'User-Agent':'SefirahSourceHub/1.0','Accept':'text/html,*/*'},redirect:'follow'});
return new Response(await r.arrayBuffer(),{status:r.status,headers:{...c,'Content-Type':r.headers.get('content-type')||'text/html'}})}}
