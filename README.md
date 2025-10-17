###################GAME MANAGER SCRIPT###########################

This script sets up a basic kitchen system for the game. It registers all station nodes in the scene, categorizes them by type, and initializes some example ingredients and recipes.
A utility function is provided to check the status of any ingredient.

For future improvements, the ingredient and recipe data could be loaded from external files (JSON or CSV) to allow easier expansion.

###################STATION SCRIPT###########################

defines the behavior of all kitchen stations in the game. Each station knows its type (Ingredient, Chopping, Cooking, or Serving) and can process ingredients, updating their status according to the station’s function.

Future improvements could include consolidating duplicate logic in interact(), implementing proper visuals in update_appearance(),
and improving physical interactions with the bot, while allowing items to be spawned, placed, taken, or transformed.
