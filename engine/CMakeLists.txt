cmake_minimum_required(VERSION 3.20)
project(ValenceEngine LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Optimization flags
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang|GNU")
    add_compile_options(-O3 -Wall -Wextra -Wpedantic)
endif()

include_directories(include)

add_library(valence_core STATIC
    src/orderbook.cpp
    src/portfolio_margin.cpp
    src/clamm_kernel.cpp
    src/matching_engine.cpp
)

add_executable(valence_benchmark src/benchmark.cpp)
target_link_libraries(valence_benchmark PRIVATE valence_core)
