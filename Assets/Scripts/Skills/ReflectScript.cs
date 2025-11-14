using UnityEngine;

public class ReflectScript : MonoBehaviour, Skill
{
    private string skillName;
    private string skillType;
    private string description;
    private float range;
    private Sprite skillSprite;
    private int cooldown;
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

    public string GetSkillName()
    {
        return skillName;
    }

    public string GetSkillType()
    {
        return skillType;
    }

    public string GetDescription()
    {
        return description;
    }

    public float GetRange()
    {
        return range;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int GetCooldown()
    {
        return cooldown;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
        currentCooldown -= number;
    }

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
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
        skillName = "Reflect";
        skillType = "Off Hand Skill";
        description = "Incoming damage is prevented and dealt to the attacker";
        cooldown = 4;
        range = 0;
        skillSprite = Resources.Load<Sprite>("Skill Sprites/Reflect");
        shield = this.transform.parent.gameObject;
        shieldScript = shield.GetComponent<ShieldScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        if (traversableTiles != null)
        {
            traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        }
        enemies = GameObject.Find("Enemies");
        if (enemies != null)
        {
            enemiesScript = enemies.GetComponent<EnemiesScript>();
        }
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null)
        {
            turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        }
    }
}
