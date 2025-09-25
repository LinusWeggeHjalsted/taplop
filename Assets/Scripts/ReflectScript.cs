using UnityEngine;

public class ReflectScript : MonoBehaviour, Skill
{
    public float range = 0;
    public int cooldown = 5;
    public int currentCooldown = 0;
    public GameObject shield;
    public ShieldScript shieldScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
 
    public float GetRange()
    {
        return range;
    }

    public int GetCurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
        currentCooldown -= number;
    }

    public void useSkill(Vector3 targetPosition)
    {
    }

    public void prepareSkill(Vector3 fromPosition)
    {
        Debug.Log("using reflect");
        GameObject wielder = null;
        if (fromPosition == player.transform.position)
        {
            wielder = player;
        }
        if (enemiesScript.enemyLookup.ContainsKey(fromPosition))
        {
            wielder = enemiesScript.enemyLookup[fromPosition];
        }
        if (wielder != null)
        {
            EntityScript wielderScript = wielder.GetComponent<EntityScript>();
            wielderScript.reflectDuration = 1;
        }
        turnLogicScript.hasAttacked = true;
        currentCooldown = cooldown;
    }

    void Start()
    {
        shield = this.transform.parent.gameObject;
        shieldScript = shield.GetComponent<ShieldScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
    }
}
