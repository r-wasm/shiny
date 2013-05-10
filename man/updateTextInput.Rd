\name{updateTextInput}
\alias{updateTextInput}
\title{Change the value of a text input on the client}
\usage{
  updateTextInput(session, inputId, label = NULL,
    value = NULL)
}
\arguments{
  \item{session}{The \code{session} object passed to
  function given to \code{shinyServer}.}

  \item{inputId}{The id of the input object.}

  \item{label}{The label to set for the input object.}

  \item{value}{The value to set for the input object.}
}
\description{
  Change the value of a text input on the client
}
\details{
  The input updater functions send a message to the client,
  telling it to change the settings of an input object. The
  messages are collected and sent after all the observers
  (including outputs) have finished running.

  The syntax of these functions is similar to the functions
  that created the inputs in the first place. For example,
  \code{\link{numericInput}()} and
  \code{updateNumericInput()} take a similar set of
  arguments.

  Any arguments with NULL values will be ignored; they will
  not result in any changes to the input object on the
  client.
}
\examples{
\dontrun{
shinyServer(function(input, output, session) {

  observe({
    # We'll use the input$controller variable multiple times, so save it as x
    # for convenience.
    x <- input$controller

    # This will change the value of input$inText, based on x
    updateTextInput(session, "inText", value = paste("New text", x))

    # Can also set the label, this time for input$inText2
    updateTextInput(session, "inText2",
      label = paste("New label", x),
      value = paste("New text", x))
  })
})
}
}
\seealso{
  \code{\link{textInput}}
}
