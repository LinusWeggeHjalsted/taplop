using UnityEngine;

public class ThatWhichLingersScript : MonoBehaviour, Skill, EnchantmentScript
{
    private string skillName;
    private string skillType;
    private string description;
    private float range;
    private float radius;
    private float distance;
    private int skillDuration;
    private int stunDuration;
    private int cooldown;
    private Sprite skillSprite;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    private int _skillBarPosition;
    public int skillBarPosition
    {
        get
        {
            return _skillBarPosition;
        }
        set
        {
            _skillBarPosition = value;
        }
    }

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

    public float GetRadius()
    {
        return radius;
    }

    public float GetDistance()
    {
        return distance;
    }

    public int GetSkillDuration()
    {
        return skillDuration;
    }

    public int GetStunDuration()
    {
        return stunDuration;
    }

    public int GetCooldown()
    {
        return cooldown;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
    {
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        if (enemyScript.GetSkillCooldown(skillName) > 0)
        {
            return -1;
        }
        // to-do - check for skills with durations about to be used
        return 0;
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition, GameObject enemy)
    {
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        wielderScript.DisplayUsedSkill(skillSprite);
        int effectiveSkillDuration = skillDuration + wielderScript.enchantmentModifiers.skillDuration;
        // create or extend enchantment
        Transform wielderEnchantments = wielderScript.enchantments;
        GameObject thatWhichLingersEnchantment;
        Transform thatWhichLingersTransform = wielderEnchantments.Find("That Which Lingers");
        if (thatWhichLingersTransform != null)
        {
            thatWhichLingersEnchantment = thatWhichLingersTransform.gameObject;
        }
        else
        {
            GameObject thatWhichLingersPrefab = Resources.Load<GameObject>("Prefabs/Skills/That Which Lingers");
            thatWhichLingersEnchantment = Instantiate(thatWhichLingersPrefab, wielderEnchantments);
            thatWhichLingersEnchantment.name = "That Which Lingers";
        }
        EnchantmentScript enchantmentScript = thatWhichLingersEnchantment.GetComponent<EnchantmentScript>();
        enchantmentScript.currentDuration += effectiveSkillDuration;
        wielderScript.DisplayEnchantments();
        wielderScript.SetSkillCooldown(skillName, cooldown);
    }

    // enchantment functions
    private int _currentDuration = 0;
    public int currentDuration
    {
        get
        {
            return _currentDuration;
        }
        set
        {
            _currentDuration = value;
            if (_currentDuration <= 0)
            {
                _currentDuration = 0;
            }
        }
    }

    public EntityScript.Modifiers ModifierEffects()
    {
        EntityScript.Modifiers modifiers = new EntityScript.Modifiers();
        modifiers.skillDuration = 1;
        return modifiers;
    }

    public void OnAttackEffect(GameObject target, GameObject wielder)
    {
    }

    public void EndOfTurnEffect(GameObject wielder)
    {
    }

    public void EndEffect(GameObject wielder)
    {
    }

    void Awake()
    {
        skillName = "That Which Lingers";
        skillType = "Enchantment";
        description = "Increase all skill durations by 1";
        range = 0;
        radius = 0;
        distance = 0;
        skillDuration = 2;
        stunDuration = 0;
        cooldown = 5;
        skillSprite = Resources.Load<Sprite>("Skills/ThatWhichLingers");
    }

    void Start()
    {
        if (LevelScript.Instance != null)
        {
            traversableTiles = LevelScript.Instance.traversableTiles;
            traversableTilesScript = LevelScript.Instance.traversableTilesScript;
            enemies = LevelScript.Instance.enemies;
            enemiesScript = LevelScript.Instance.enemiesScript;
            player = LevelScript.Instance.player;
            turnLogic = LevelScript.Instance.turnLogic;
            turnLogicScript = LevelScript.Instance.turnLogicScript;
        }
    }
}
