# This file contains a general toolkit for routing and combining bits of
# HTTP-handling logic. It is similar in spirit to Rook (and Rack, and WSGI, and
# Connect, and...) but adds cascading and routing.
#
# This file is called "middleware" because that's the term used for these bits
# of logic in these other frameworks. However, our code uses the word "handler"
# so we'll stick to that for the rest of this document; just know that they're
# basically the same concept.
#
# ## Intro to handlers
#
# A **handler** (or sometimes, **httpHandler**) is a function that takes a
# `req` parameter--a request object as described in the Rook specification--and
# returns `NULL`, or an `httpResponse`.
#
## ------------------------------------------------------------------------
httpResponse <- function(status = 200,
                         content_type = "text/html; charset=UTF-8",
                         content = "",
                         headers = list()) {
  # Make sure it's a list, not a vector
  headers <- as.list(headers)
  if (is.null(headers$`X-UA-Compatible`))
    headers$`X-UA-Compatible` <- "chrome=1"
  resp <- list(status = status, content_type = content_type, content = content,
               headers = headers)
  class(resp) <- 'httpResponse'
  return(resp)
}

#
# You can think of a web application as being simply an aggregation of these
# functions, each of which performs one kind of duty. Each handler in turn gets
# a look at the request and can decide whether it knows how to handle it. If
# so, it returns an `httpResponse` and processing terminates; if not, it
# returns `NULL` and the next handler gets to execute. If the final handler
# returns `NULL`, a 404 response should be returned.
#
# We have a similar construct for websockets: **websocket handlers** or
# **wsHandlers**. These take a single `ws` argument which is the websocket
# connection that was just opened, and they can either return `TRUE` if they
# are handling the connection, and `NULL` to pass responsibility on to the next
# wsHandler.
#
# ### Combining handlers
#
# Since it's so common for httpHandlers to be invoked in this "cascading"
# fashion, we'll introduce a function that takes zero or more handlers and
# returns a single handler. And while we're at it, making a directory of static
# content available is such a common thing to do, we'll allow strings
# representing paths to be used instead of handlers; any such strings we
# encounter will be converted into `staticHandler` objects.
#
## ------------------------------------------------------------------------
joinHandlers <- function(handlers) {
  # Zero handlers; return a null handler
  if (length(handlers) == 0)
    return(function(req) NULL)

  # Just one handler (function)? Return it.
  if (is.function(handlers))
    return(handlers)

  handlers <- lapply(handlers, function(h) {
    if (is.character(h))
      return(staticHandler(h))
    else
      return(h)
  })

  # Filter out NULL
  handlers <- handlers[!sapply(handlers, is.null)]

  if (length(handlers) == 0)
    return(function(req) NULL)
  if (length(handlers) == 1)
    return(handlers[[1]])

  function(req) {
    for (handler in handlers) {
      response <- handler(req)
      if (!is.null(response))
        return(response)
    }
    return(NULL)
  }
}

#
# Note that we don't have an equivalent of `joinHandlers` for wsHandlers. It's
# easy to imagine it, we just haven't needed one.
#
# ### Handler routing
#
# Handlers do not have a built-in notion of routing. Conceptually, given a list
# of handlers, all the handlers are peers and they all get to see every request
# (well, up until the point that a handler returns a response).
#
# You could implement routing in each handler by checking the request's
# `PATH_INFO` field, but since it's such a common need, let's make it simple by
# introducing a `routeHandler` function. This is a handler
# [decorator](http://en.wikipedia.org/wiki/Decorator_pattern) and it's
# responsible for 1) filtering out requests that don't match the given route,
# and 2) temporarily modifying the request object to take the matched part of
# the route off of the `PATH_INFO` (and add it to the end of `SCRIPT_NAME`).
# This way, the handler doesn't need to figure out about what part of its URL
# path has already been matched via routing.
#
# (BTW, it's safe for `routeHandler` calls to nest.)
#
## ------------------------------------------------------------------------
routeHandler <- function(prefix, handler) {
  force(prefix)
  force(handler)

  if (identical("", prefix))
    return(handler)

  if (length(prefix) != 1 || !isTRUE(grepl("^/[^\\]+$", prefix))) {
    stop("Invalid URL prefix \"", prefix, "\"")
  }

  pathPattern <- paste("^\\Q", prefix, "\\E/", sep = "")
  function(req) {
    if (isTRUE(grepl(pathPattern, req$PATH_INFO))) {
      origScript <- req$SCRIPT_NAME
      origPath <- req$PATH_INFO
      on.exit({
        req$SCRIPT_NAME <- origScript
        req$PATH_INFO <- origPath
      }, add = TRUE)
      pathInfo <- substr(req$PATH_INFO, nchar(prefix)+1, nchar(req$PATH_INFO))
      req$SCRIPT_NAME <- paste(req$SCRIPT_NAME, prefix, sep = "")
      req$PATH_INFO <- pathInfo
      return(handler(req))
    } else {
      return(NULL)
    }
  }
}

#
# We have a version for websocket handlers as well. Pity about the copy/paste
# job.
#
## ------------------------------------------------------------------------
routeWSHandler <- function(prefix, wshandler) {
  force(prefix)
  force(wshandler)

  if (identical("", prefix))
    return(wshandler)

  if (length(prefix) != 1 || !isTRUE(grepl("^/[^\\]+$", prefix))) {
    stop("Invalid URL prefix \"", prefix, "\"")
  }

  pathPattern <- paste("^\\Q", prefix, "\\E/", sep = "")
  function(ws) {
    req <- ws$request
    if (isTRUE(grepl(pathPattern, req$PATH_INFO))) {
      origScript <- req$SCRIPT_NAME
      origPath <- req$PATH_INFO
      on.exit({
        req$SCRIPT_NAME <- origScript
        req$PATH_INFO <- origPath
      }, add = TRUE)
      pathInfo <- substr(req$PATH_INFO, nchar(prefix)+1, nchar(req$PATH_INFO))
      req$SCRIPT_NAME <- paste(req$SCRIPT_NAME, prefix, sep = "")
      req$PATH_INFO <- pathInfo
      return(wshandler(ws))
    } else {
      return(NULL)
    }
  }
}

#
# ### Handler implementations
#
# Now let's actually write some handlers. Note that these functions aren't
# *themselves* handlers, you call them and they *return* a handler. Handler
# factory functions, if you will.
#
# Here's one that serves up static assets from a directory.
#
## ------------------------------------------------------------------------
staticHandler <- function(root) {
  force(root)
  return(function(req) {
    if (!identical(req$REQUEST_METHOD, 'GET'))
      return(NULL)

    path <- req$PATH_INFO

    if (is.null(path))
      return(httpResponse(400, content="<h1>Bad Request</h1>"))

    if (path == '/')
      path <- '/index.html'

    abs.path <- resolve(root, path)
    if (is.null(abs.path))
      return(NULL)

    ext <- tools::file_ext(abs.path)
    content.type <- getContentType(ext)
    response.content <- readBin(abs.path, 'raw', n=file.info(abs.path)$size)
    return(httpResponse(200, content.type, response.content))
  })
}

#
# ## Handler manager
#
# The handler manager gives you a place to register handlers (of both http and
# websocket varieties) and provides an httpuv-compatible set of callbacks for
# invoking them.
#
# Create one of these, make zero or more calls to `addHandler` and
# `addWSHandler` methods (order matters--first one wins!), and then pass the
# return value of `createHttpuvApp` to httpuv's `startServer` function.
#
## ------------------------------------------------------------------------
HandlerList <- setRefClass("HandlerList",
  fields = list(
    handlers = "list"
  ),
  methods = list(
    add = function(handler, key, tail = FALSE) {
      if (!is.null(handlers[[key]]))
        stop("Key ", key, " already in use")
      newList <- structure(names=key, list(handler))

      if (length(handlers) == 0)
        handlers <<- newList
      else if (tail)
        handlers <<- c(handlers, newList)
      else
        handlers <<- c(newList, handlers)
    },
    remove = function(key) {
      handlers[key] <<- NULL
    },
    clear = function() {
      handlers <<- list()
    },
    invoke = function(...) {
      for (handler in handlers) {
        result <- handler(...)
        if (!is.null(result))
          return(result)
      }
      return(NULL)
    }
  )
)

HandlerManager <- setRefClass("HandlerManager",
  fields = list(
    handlers = "HandlerList",
    wsHandlers = "HandlerList"
  ),
  methods = list(
    addHandler = function(handler, key, tail = FALSE) {
      handlers$add(handler, key, tail)
    },
    removeHandler = function(key) {
      handlers$remove(key)
    },
    addWSHandler = function(wsHandler, key, tail = FALSE) {
      wsHandlers$add(wsHandler, key, tail)
    },
    removeWSHandler = function(key) {
      wsHandlers$remove(key)
    },
    clear = function() {
      handlers$clear()
      wsHandlers$clear()
    },
    createHttpuvApp = function() {
      list(
        onHeaders = function(req) {
          maxSize <- getOption('shiny.maxRequestSize', 5 * 1024 * 1024)
          if (maxSize <= 0)
            return(NULL)

          reqSize <- 0
          if (length(req$CONTENT_LENGTH) > 0)
            reqSize <- as.numeric(req$CONTENT_LENGTH)
          else if (length(req$HTTP_TRANSFER_ENCODING) > 0)
            reqSize <- Inf

          if (reqSize > maxSize) {
            return(list(status = 413L,
              headers = list(
                'Content-Type' = 'text/plain'
              ),
              body = 'Maximum upload size exceeded'))
          }
          else {
            return(NULL)
          }
        },
        call = .httpServer(
          function (req) {
            return(handlers$invoke(req))
          },
          getOption('shiny.sharedSecret', NULL)
        ),
        onWSOpen = function(ws) {
          return(wsHandlers$invoke(ws))
        }
      )
    },
    .httpServer = function(handler, sharedSecret) {
      filter <- getOption('shiny.http.response.filter', NULL)
      if (is.null(filter))
        filter <- function(req, response) response

      function(req) {
        if (!is.null(sharedSecret)
          && !identical(sharedSecret, req$HTTP_SHINY_SHARED_SECRET)) {
          return(list(status=403,
            body='<h1>403 Forbidden</h1><p>Shared secret mismatch</p>',
            headers=list('Content-Type' = 'text/html')))
        }

        response <- handler(req)
        if (is.null(response))
          response <- httpResponse(404, content="<h1>Not Found</h1>")
        
        if (inherits(response, "httpResponse")) {
          headers <- as.list(response$headers)
          headers$'Content-Type' <- response$content_type
  
          response <- filter(req, response)
          return(list(status=response$status,
            body=response$content,
            headers=headers))
        } else {
          # Assume it's a Rook-compatible response
          return(response)
        }
      }
    }
  )
)

#
# ## Next steps
#
# See server.R and middleware-shiny.R to see actual implementation and usage of
# handlers in the context of Shiny.