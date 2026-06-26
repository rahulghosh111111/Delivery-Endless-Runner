<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use App\Http\Controllers\Api\GameSessionController;

// Existing routes might go here...

Route::middleware('auth:sanctum')->group(function () {
    // ...your existing routes...

    Route::prefix('game')->group(function () {
        Route::post('/sessions', [GameSessionController::class, 'start']);
        Route::patch('/sessions/{sessionId}/sync', [GameSessionController::class, 'sync']);
        Route::post('/sessions/{sessionId}/complete', [GameSessionController::class, 'complete']);
    });
});
