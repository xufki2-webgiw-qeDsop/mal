if(!exists("..readline..")) source("readline.r")
if(!exists("..types..")) source("types.r")
if(!exists("..reader..")) source("reader.r")
if(!exists("..printer..")) source("printer.r")
if(!exists("..env..")) source("env.r")
if(!exists("..core..")) source("core.r")

# read
READ <- function(str) {
    return(read_str(str))
}

# eval
is_pair <- function(x) {
    .sequential_q(x) && length(x) > 0
}

quasiquote <- function(ast) {
    if (!is_pair(ast)) {
        new.list(new.symbol("quote"),
                 ast)
    } else if (.symbol_q(ast[[1]]) && ast[[1]] == "unquote") {
        ast[[2]]
    } else if (is_pair(ast[[1]]) &&
               .symbol_q(ast[[1]][[1]]) &&
               ast[[1]][[1]] == "splice-unquote") {
        new.list(new.symbol("concat"),
                 ast[[1]][[2]],
                 quasiquote(slice(ast, 2)))
    } else {
        new.list(new.symbol("cons"),
                 quasiquote(ast[[1]]),
                 quasiquote(slice(ast, 2)))
    }
}

is_macro_call <- function(ast, env) {
    if(.list_q(ast) &&
      .symbol_q(ast[[1]]) &&
      (!.nil_q(Env.find(env, ast[[1]])))) {
        exp <- Env.get(env, ast[[1]])
        return(.malfunc_q(exp) && exp$ismacro)
    }
    FALSE
}

macroexpand <- function(ast, env) {
    while(is_macro_call(ast, env)) {
        mac <- Env.get(env, ast[[1]])
        ast <- fapply(mac, slice(ast, 2))
    }
    ast
}

eval_ast <- function(ast, env) {
    if (.symbol_q(ast)) {
        Env.get(env, ast)
    } else if (.list_q(ast)) {
        new.listl(lapply(ast, function(a) EVAL(a, env)))
    } else if (.vector_q(ast)) {
        new.vectorl(lapply(ast, function(a) EVAL(a, env)))
    } else if (.hash_map_q(ast)) {
        lst <- list()
        for(k in ls(ast)) {
            lst[[length(lst)+1]] = k
            lst[[length(lst)+1]] = EVAL(ast[[k]], env)
        }
        new.hash_mapl(lst)
    } else {
        ast
    }
}

EVAL <- function(ast, env) {
    repeat {

    #cat("EVAL: ", .pr_str(ast,TRUE), "\n", sep="")
    if (!.list_q(ast)) {
        return(eval_ast(ast, env))
    }

    # apply list
    ast <- macroexpand(ast, env)
    if (!.list_q(ast)) return(eval_ast(ast, env))

    switch(paste("l",length(ast),sep=""),
           l0={ return(ast) },
           l1={ a0 <- ast[[1]]; a1 <- NULL;     a2 <- NULL },
           l2={ a0 <- ast[[1]]; a1 <- ast[[2]]; a2 <- NULL },
              { a0 <- ast[[1]]; a1 <- ast[[2]]; a2 <- ast[[3]] })
    if (length(a0) > 1) a0sym <- "__<*fn*>__"
    else                a0sym <- as.character(a0)
    if (a0sym == "def!") {
        res <- EVAL(a2, env)
        return(Env.set(env, a1, res))
    } else if (a0sym == "let*") {
        let_env <- new.Env(env)
        for(i in seq(1,length(a1),2)) {
            Env.set(let_env, a1[[i]], EVAL(a1[[i+1]], let_env))
        }
        ast <- a2
        env <- let_env
    } else if (a0sym == "quote") {
        return(a1)
    } else if (a0sym == "quasiquote") {
        ast <- quasiquote(a1)
    } else if (a0sym == "defmacro!") {
        func <- EVAL(a2, env)
        func$ismacro = TRUE
        return(Env.set(env, a1, func))
    } else if (a0sym == "macroexpand") {
        return(macroexpand(a1, env))
    } else if (a0sym == "try*") {
        edata <- new.env()
        tryCatch({
            return(EVAL(a1, env))
        }, error=function(err) {
            edata$exc <- get_error(err)
        })
        if ((!is.null(a2)) && a2[[1]] == "catch*") {
            return(EVAL(a2[[3]], new.Env(env,
                                         new.list(a2[[2]]),
                                         new.list(edata$exc))))
        } else {
            throw(err)
        }
    } else if (a0sym == "do") {
        eval_ast(slice(ast,2,length(ast)-1), env)
        ast <- ast[[length(ast)]]
    } else if (a0sym == "if") {
        cond <- EVAL(a1, env)
        if (.nil_q(cond) || identical(cond, FALSE)) {
            if (length(ast) < 4) return(nil)
            ast <- ast[[4]]
        } else {
            ast <- a2
        }
    } else if (a0sym == "fn*") {
        return(malfunc(EVAL, a2, env, a1))
    } else {
        el <- eval_ast(ast, env)
        f <- el[[1]]
        if (class(f) == "MalFunc") {
            ast <- f$ast
            env <- f$gen_env(slice(el,2))
        } else {
            return(do.call(f,slice(el,2)))
        }
    }

    }
}

# print
PRINT <- function(exp) {
    return(.pr_str(exp, TRUE))
}

# repl loop
repl_env <- new.Env()
rep <- function(str) return(PRINT(EVAL(READ(str), repl_env)))

# core.r: defined using R
for(k in names(core_ns)) { Env.set(repl_env, k, core_ns[[k]]) }
Env.set(repl_env, "eval", function(ast) EVAL(ast, repl_env))
Env.set(repl_env, "*ARGV*", new.list())

# core.mal: defined using the language itself
. <- rep("(def! *host-language* \"R\")")
. <- rep("(def! not (fn* (a) (if a false true)))")
. <- rep("(def! load-file (fn* (f) (eval (read-string (str \"(do \" (slurp f) \")\")))))")
. <- rep("(defmacro! cond (fn* (& xs) (if (> (count xs) 0) (list 'if (first xs) (if (> (count xs) 1) (nth xs 1) (throw \"odd number of forms to cond\")) (cons 'cond (rest (rest xs)))))))")
. <- rep("(def! *gensym-counter* (atom 0))")
. <- rep("(def! gensym (fn* [] (symbol (str \"G__\" (swap! *gensym-counter* (fn* [x] (+ 1 x)))))))")
. <- rep("(defmacro! or (fn* (& xs) (if (empty? xs) nil (if (= 1 (count xs)) (first xs) (let* (condvar (gensym)) `(let* (~condvar ~(first xs)) (if ~condvar ~condvar (or ~@(rest xs)))))))))")


args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 0) {
    Env.set(repl_env, "*ARGV*", new.listl(slice(list(args),2)))
    tryCatch({
        . <- rep(concat("(load-file \"", args[[1]], "\")"))
    }, error=function(err) {
        cat("Error: ", get_error(err),"\n", sep="")
    })
    quit(save="no", status=0)
}

. <- rep("(println (str \"Mal [\" *host-language* \"]\"))")
repeat {
    line <- readline("user> ")
    if (is.null(line)) { cat("\n"); break }
    tryCatch({
        cat(rep(line),"\n", sep="")
    }, error=function(err) {
        cat("Error: ", get_error(err),"\n", sep="")
    })
    # R debug/fatal with tracebacks:
    #cat(rep(line),"\n", sep="")
}
