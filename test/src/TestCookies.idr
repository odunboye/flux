module TestCookies

import Flux.Core.HTTP
import Flux.Core.Middleware
import Flux.Middleware.Cookies
import Data.SortedMap

%default total

-- cookie / renderSetCookie

export
testCookieDefaults : Bool
testCookieDefaults =
  let c = cookie "a" "b"
   in c.path == "/" && c.httpOnly == True && c.secure == False && c.maxAge == Nothing

export
testRenderSetCookieBasic : Bool
testRenderSetCookieBasic =
  renderSetCookie (cookie "session" "abc123") == "session=abc123; Path=/; HttpOnly"

export
testRenderSetCookieWithMaxAgeAndSecure : Bool
testRenderSetCookieWithMaxAgeAndSecure =
  let c = { maxAge := Just 3600, secure := True } (cookie "session" "abc123")
   in renderSetCookie c == "session=abc123; Path=/; Max-Age=3600; HttpOnly; Secure"

export
testRenderSetCookieNotHttpOnly : Bool
testRenderSetCookieNotHttpOnly =
  let c = { httpOnly := False } (cookie "a" "b")
   in renderSetCookie c == "a=b; Path=/"

-- A ";" in a cookie value would otherwise inject a bogus attribute
-- ("Secure=false" here) into the rendered Set-Cookie line.
export
testRenderSetCookieStripsSemicolonInValue : Bool
testRenderSetCookieStripsSemicolonInValue =
  let c = { httpOnly := False } (cookie "a" "b; Secure=false")
   in renderSetCookie c == "a=b Secure=false; Path=/"

-- CR/LF in a cookie value would otherwise inject an entire extra
-- header line into the response.
export
testRenderSetCookieStripsCRLFInValue : Bool
testRenderSetCookieStripsCRLFInValue =
  let c = { httpOnly := False } (cookie "a" "b\r\nX-Injected: evil")
   in renderSetCookie c == "a=bX-Injected: evil; Path=/"

-- parseCookies (against a dummy Request)

dummyRequestWithCookies : String -> Request
dummyRequestWithCookies cookieHeader =
  R GET "/" empty V11 (fromList [("cookie", cookieHeader)]) 0 Nothing (pure (pure ()))

dummyRequestNoCookies : Request
dummyRequestNoCookies = R GET "/" empty V11 empty 0 Nothing (pure (pure ()))

export
testParseCookiesSingle : Bool
testParseCookiesSingle =
  lookup "name" (parseCookies (dummyRequestWithCookies "name=value")) == Just "value"

export
testParseCookiesMultiple : Bool
testParseCookiesMultiple =
  let cookies = parseCookies (dummyRequestWithCookies "a=1; b=2")
   in lookup "a" cookies == Just "1" && lookup "b" cookies == Just "2"

export
testParseCookiesAbsent : Bool
testParseCookiesAbsent = null (SortedMap.toList (parseCookies dummyRequestNoCookies))

-- Context helpers

export
testGetCookie : Bool
testGetCookie =
  getCookie "name" (emptyContext (dummyRequestWithCookies "name=value")) == Just "value"

export
testGetCookieMissing : Bool
testGetCookieMissing =
  getCookie "missing" (emptyContext (dummyRequestWithCookies "name=value")) == Nothing

export
testSetCookieAddsToRespCookies : Bool
testSetCookieAddsToRespCookies =
  let ctx = setCookie "session" "xyz" (emptyContext dummyRequestNoCookies)
   in case ctx.respCookies of
        [c] => c.name == "session" && c.value == "xyz"
        _   => False

-- Run all cookie tests
export
runAllTests : List (String, Bool)
runAllTests = [
  ("cookieDefaults", testCookieDefaults),
  ("renderSetCookieBasic", testRenderSetCookieBasic),
  ("renderSetCookieWithMaxAgeAndSecure", testRenderSetCookieWithMaxAgeAndSecure),
  ("renderSetCookieNotHttpOnly", testRenderSetCookieNotHttpOnly),
  ("renderSetCookieStripsSemicolonInValue", testRenderSetCookieStripsSemicolonInValue),
  ("renderSetCookieStripsCRLFInValue", testRenderSetCookieStripsCRLFInValue),
  ("parseCookiesSingle", testParseCookiesSingle),
  ("parseCookiesMultiple", testParseCookiesMultiple),
  ("parseCookiesAbsent", testParseCookiesAbsent),
  ("getCookie", testGetCookie),
  ("getCookieMissing", testGetCookieMissing),
  ("setCookieAddsToRespCookies", testSetCookieAddsToRespCookies)
  ]
