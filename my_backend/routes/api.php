<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use App\Http\Controllers\Api\GameSessionController;

// Existing routes might go here...

Route::middleware('auth:sanctum')->group(function () {
    Route::prefix('game')->group(function () {
        Route::post('/start', [GameSessionController::class, 'start']);
        Route::post('/{sessionId}/sync', [GameSessionController::class, 'sync']);
        Route::post('/{sessionId}/complete', [GameSessionController::class, 'complete']);
        Route::post('/redeem', [GameSessionController::class, 'redeem']);
    });
});
