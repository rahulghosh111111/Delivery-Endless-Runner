<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\GameSession;
use App\Models\GameBestScore;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Carbon\Carbon;

/**
 * Backs the Flutter DeliveryEndlessRunnerGame screen.
 */
class GameSessionController extends Controller
{
    private const MAX_SCORE_PER_SECOND = 6.0; // generous ceiling, tune from playtesting
    private const MAX_COINS_PER_SECOND = 0.50; // increased from 0.35 to account for bonus coins

    public function start(Request $request)
    {
        $validated = $request->validate([
            'duration_seconds' => 'sometimes|integer|min:60|max:3600',
        ]);

        $duration = $validated['duration_seconds'] ?? 1800;
        $startsAt = Carbon::now();
        $endsAt = $startsAt->copy()->addSeconds($duration);

        $session = GameSession::create([
            'id' => (string) Str::uuid(),
            'user_id' => $request->user()->id,
            'starts_at' => $startsAt,
            'ends_at' => $endsAt,
            'duration_seconds' => $duration,
            'status' => 'active',
        ]);

        $best = GameBestScore::where('user_id', $request->user()->id)->first();

        return response()->json([
            'data' => [
                'session_id' => $session->id,
                'starts_at' => $session->starts_at->toIso8601String(),
                'ends_at' => $session->ends_at->toIso8601String(),
                'best_score' => $best->best_score ?? 0,
                'lifetime_coins' => $request->user()->lifetime_coins,
                'pending_rewards' => floor($request->user()->lifetime_coins / 10000) * 5,
            ],
        ], 201);
    }

    public function sync(Request $request, string $sessionId)
    {
        $validated = $request->validate([
            'score' => 'required|integer|min:0',
            'coins' => 'required|integer|min:0',
            'distance' => 'required|numeric|min:0',
        ]);

        $session = GameSession::where('id', $sessionId)
            ->where('user_id', $request->user()->id)
            ->where('status', 'active')
            ->firstOrFail();

        $elapsed = max(1, Carbon::now()->diffInSeconds($session->starts_at));
        $maxPlausibleScore = (int) ($elapsed * self::MAX_SCORE_PER_SECOND);
        $maxPlausibleCoins = (int) ($elapsed * self::MAX_COINS_PER_SECOND);

        $validatedCoins = min($validated['coins'], $maxPlausibleCoins);
        
        DB::transaction(function () use ($session, $validated, $validatedCoins, $maxPlausibleScore, $request) {
            $deltaCoins = $validatedCoins - $session->coins;
            
            $session->update([
                'score' => min($validated['score'], $maxPlausibleScore),
                'coins' => $validatedCoins,
                'distance' => $validated['distance'],
            ]);
            
            if ($deltaCoins > 0) {
                $user = $request->user();
                $user->increment('lifetime_coins', $deltaCoins);
            }
        });

        return response()->json(['data' => ['ok' => true]]);
    }

    public function complete(Request $request, string $sessionId)
    {
        $validated = $request->validate([
            'score' => 'required|integer|min:0',
            'coins' => 'required|integer|min:0',
            'distance' => 'required|numeric|min:0',
        ]);

        $session = GameSession::where('id', $sessionId)
            ->where('user_id', $request->user()->id)
            ->where('status', 'active')
            ->firstOrFail();

        $elapsed = max(1, Carbon::now()->diffInSeconds($session->starts_at));
        $finalScore = min($validated['score'], (int) ($elapsed * self::MAX_SCORE_PER_SECOND));
        $finalCoins = min($validated['coins'], (int) ($elapsed * self::MAX_COINS_PER_SECOND));

        $best = null;

        DB::transaction(function () use ($request, $session, $validated, $finalScore, $finalCoins, &$best) {
            $deltaCoins = $finalCoins - $session->coins;

            $session->update([
                'score' => $finalScore,
                'coins' => $finalCoins,
                'distance' => $validated['distance'],
                'status' => 'completed',
                'reward_coins' => $finalCoins,
            ]);

            if ($deltaCoins > 0) {
                $request->user()->increment('lifetime_coins', $deltaCoins);
            }

            $best = GameBestScore::firstOrCreate(
                ['user_id' => $request->user()->id],
                ['best_score' => 0],
            );
            
            if ($finalScore > $best->best_score) {
                $best->update(['best_score' => $finalScore]);
            }

            // Generic wallet crediting logic
            // e.g., $request->user()->wallet()->increment('balance', $finalCoins);
            Log::info("Credited {$finalCoins} coins to user {$request->user()->id}");
        });

        // Mock FCM Push notification
        Log::info("FCM Push sent to user {$request->user()->id}: Delivery complete! You earned {$finalCoins} coins this run.");

        return response()->json([
            'data' => [
                'best_score' => $best->best_score,
                'reward_coins' => $finalCoins,
                'lifetime_coins' => $request->user()->fresh()->lifetime_coins,
            ],
        ]);
    }

    public function redeem(Request $request)
    {
        $user = $request->user();
        
        if ($user->lifetime_coins < 100000) {
            return response()->json([
                'message' => 'Insufficient coins to redeem.',
            ], 400);
        }

        $amount = 50; // ₹50 for 100,000 coins

        DB::transaction(function () use ($user, $amount) {
            DB::table('reward_redemptions')->insert([
                'user_id' => $user->id,
                'amount' => $amount,
                'coins_at_redemption' => $user->lifetime_coins,
                'created_at' => Carbon::now(),
                'updated_at' => Carbon::now(),
            ]);

            $user->update(['lifetime_coins' => 0]);

            // TODO: Credit User Wallet (Stripe, Internal Ledger, etc.)
            // $user->wallet()->increment('balance', $amount);
        });

        Log::info("User {$user->id} redeemed {$amount} rewards and reset lifetime_coins.");

        return response()->json([
            'data' => [
                'lifetime_coins' => 0,
                'pending_rewards' => 0,
            ],
        ]);
    }
}
