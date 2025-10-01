using UnityEngine;

public class ReflectScript : MonoBehaviour, Skill
{
    public string description = "Incoming damage is prevented and dealt to the attacker";
    public float range = 0;
    public int cooldown = 5;
    private int currentCooldown = 0;
    public GameObject shield;
    public ShieldScript shieldScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
     
    public string GetDescription()
    {
        return description;
    }

    public float GetRange()
    {
        return range;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
        currentCooldown -= number;
    }

    public int EnemyPriority(Vector3 fromPosition)
    {
        if (currentCooldown > 0)
        {
            return -1;
        }
        Vector3 playerPosition = player.transform.position;
        EntityScript playerScript = player.GetComponent<EntityScript>();
        float distanceFromPlayer = traversableTilesScript.Distance(playerPosition, fromPosition);
        if (distanceFromPlayer > playerScript.minRange)
        {
            return -1;
        }
        else
        {
            return 1;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition)
    {
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        if (wielder != null)
        {
            Debug.Log(wielder.name + " using reflect");
            EntityScript wielderScript = wielder.GetComponent<EntityScript>();
            wielderScript.reflectDuration += 1;
        }
        if (wielder == player)
        {
            turnLogicScript.hasAttacked = true;
        }
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
