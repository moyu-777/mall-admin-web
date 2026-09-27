'use strict'
module.exports = {
  NODE_ENV: '"production"',
  // 空字符串 = axios 走相对路径，请求打到当前 origin（nginx），
  // 再由 nginx.conf 里的 location 反代给 mall-admin 的 Service。
  //
  // 好处：同源不需要 CORS，而且产物里不硬编码 IP/域名，换环境不用重新构建。
  //
  // 原来是 'https://admin-api.macrozheng.com'（原作者的 demo 域名），
  // 在你这套环境里根本访问不到，必须改掉。
  BASE_API: '""'
}
